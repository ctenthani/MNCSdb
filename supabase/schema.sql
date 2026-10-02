-- Run once in a new Supabase project. Provision auth users in the dashboard,
-- then insert their profiles here using a trusted administrator connection.
create table public.profiles (
 id uuid primary key references auth.users(id),
 role text not null check(role in ('admin','reviewer','association')),
 association_id text,
 check(role <> 'association' or association_id is not null)
);
create table public.registry (
 collection text not null check(collection in ('associations','players','events','results')),
 id text not null,
 payload jsonb not null,
 primary key(collection,id)
);
create table public.submissions (
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
create unique index unique_current_submission on public.submissions(association_id,kind,period) where status in ('Draft','Submitted','Approved');
alter table public.profiles enable row level security;
alter table public.registry enable row level security;
alter table public.submissions enable row level security;
create function public.is_reviewer() returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from profiles where id=auth.uid() and role in ('admin','reviewer')); $$;
create policy profile_self on public.profiles for select to authenticated using(id=auth.uid());
create policy registry_public on public.registry for select using(true);
create policy submission_read on public.submissions for select to authenticated using(public.is_reviewer() or association_id=(select association_id from profiles where id=auth.uid()));
create policy submission_create on public.submissions for insert to authenticated with check(
 created_by=auth.uid() and status='Draft' and history='[]'::jsonb and review_comment is null
 and association_id=(select association_id from profiles where id=auth.uid() and role='association')
 and (document_path is null or document_path=association_id||'/'||id::text||'.pdf')
 and (kind='Profile update' or document_path is not null)
);
-- No direct update/delete policies. Status changes use this guarded transaction.
create function public.transition_submission(submission_id uuid,next_status text,comment text default '') returns void
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
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('association-documents','association-documents',false,10485760,array['application/pdf']);
create policy document_read on storage.objects for select to authenticated using(bucket_id='association-documents' and (public.is_reviewer() or (storage.foldername(name))[1]=(select association_id from profiles where id=auth.uid())));
create policy document_upload on storage.objects for insert to authenticated with check(bucket_id='association-documents' and (storage.foldername(name))[1]=(select association_id from profiles where id=auth.uid() and role='association'));
