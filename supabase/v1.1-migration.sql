-- V1.1: national registry with independently operated association sites.
create table if not exists public.association_connectors(
 id uuid primary key default gen_random_uuid(),association_id text not null unique,
 name text not null,site_url text not null,token_hash text not null,enabled boolean not null default true,
 created_by uuid not null references auth.users(id),created_at timestamptz not null default now(),
 rotated_at timestamptz not null default now(),last_received_at timestamptz
);
create table if not exists public.association_exchange(
 id uuid primary key default gen_random_uuid(),connector_id uuid not null references public.association_connectors(id),
 association_id text not null,kind text not null check(kind in ('Competition','Performance summary','Annual report','Funding request','Travel abroad','MRA clearance','Other request','Award nomination')),
 external_id text not null,revision integer not null check(revision>0),period text not null,
 payload jsonb not null,payload_hash text not null,source_url text not null,status text not null,
 published_payload jsonb,submission_id uuid references public.submissions(id),review_comment text not null default '',
 history jsonb not null default '[]',received_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 unique(connector_id,kind,external_id)
);
alter table public.association_connectors enable row level security;
alter table public.association_exchange enable row level security;
revoke all on public.association_connectors,public.association_exchange from anon,authenticated;
grant select on public.association_exchange to authenticated;
drop policy if exists exchange_read on public.association_exchange;
create policy exchange_read on public.association_exchange for select to authenticated using(public.is_reviewer() or association_id=(select association_id from public.profiles where id=auth.uid() and role='association'));

create or replace function public.connector_status() returns setof jsonb language sql stable security definer set search_path=public as $$
 select jsonb_build_object('id',id,'association_id',association_id,'name',name,'site_url',site_url,'enabled',enabled,'last_received_at',last_received_at,'rotated_at',rotated_at)
 from public.association_connectors where public.is_reviewer() or association_id=(select association_id from public.profiles where id=auth.uid() and role='association');
$$;
revoke all on function public.connector_status() from public,anon;
grant execute on function public.connector_status() to authenticated;

create or replace function public.configure_association_connector(owner_id text,website text,connector_name text) returns jsonb language plpgsql security definer set search_path=public as $$
declare secret text;key uuid;
begin
 if not public.is_admin() then raise exception 'MNCS administrator required'; end if;
 if not exists(select 1 from public.registry where collection='associations' and id=owner_id) then raise exception 'Select a registered association'; end if;
 if website !~ '^https://[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]/?$' or length(website)>250 or coalesce(length(trim(connector_name)),0) not between 1 and 120 then raise exception 'Use an HTTPS site origin and connector name'; end if;
 secret=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
 insert into public.association_connectors(association_id,name,site_url,token_hash,created_by)
 values(owner_id,trim(connector_name),rtrim(website,'/'),encode(sha256(convert_to(secret,'UTF8')),'hex'),auth.uid())
 on conflict(association_id) do update set name=excluded.name,site_url=excluded.site_url,token_hash=excluded.token_hash,enabled=true,rotated_at=now(),last_received_at=null returning id into key;
 return jsonb_build_object('connectorId',key,'token',secret,'associationId',owner_id,'siteUrl',rtrim(website,'/'));
end $$;
revoke all on function public.configure_association_connector(text,text,text) from public,anon;
grant execute on function public.configure_association_connector(text,text,text) to authenticated;

create or replace function public.set_connector_enabled(connector uuid,active boolean) returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.is_admin() then raise exception 'MNCS administrator required'; end if;
 update public.association_connectors set enabled=active where id=connector;
 if not found then raise exception 'Connector not found'; end if;
end $$;
revoke all on function public.set_connector_enabled(uuid,boolean) from public,anon;
grant execute on function public.set_connector_enabled(uuid,boolean) to authenticated;

create or replace function public.check_connector(connector uuid,secret text) returns public.association_connectors language plpgsql security definer set search_path=public as $$
declare c public.association_connectors;
begin
 select * into c from public.association_connectors where id=connector and enabled and length(secret)=64 and token_hash=encode(sha256(convert_to(secret,'UTF8')),'hex');
 if c.id is null then raise exception 'Integration credentials invalid or disabled'; end if;
 return c;
end $$;
revoke all on function public.check_connector(uuid,text) from public,anon,authenticated;

create or replace function public.integration_receipts(connector uuid,secret text) returns setof jsonb language plpgsql security definer set search_path=public as $$
declare c public.association_connectors;
begin
 c=public.check_connector(connector,secret);
 return query select jsonb_build_object('id',e.id,'kind',e.kind,'externalId',e.external_id,'revision',e.revision,'status',e.status,'comment',e.review_comment,'submissionId',e.submission_id,'updatedAt',e.updated_at) from public.association_exchange e where e.connector_id=c.id order by updated_at desc limit 500;
end $$;
revoke all on function public.integration_receipts(uuid,text) from public;
grant execute on function public.integration_receipts(uuid,text) to anon,authenticated,service_role;

create or replace function public.receive_association_message(connector uuid,secret text,message jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare c public.association_connectors;e public.association_exchange;s public.submissions;v jsonb;clean jsonb;entry jsonb;leaders jsonb='[]';kind_name text;external_key text;year_text text;rev integer;digest text;key uuid;comp public.association_exchange;field text;
begin
 c=public.check_connector(connector,secret);
 perform pg_advisory_xact_lock(hashtextextended(c.id::text,1101));
 if jsonb_typeof(message)<>'object' or octet_length(message::text)>65536 or message->>'revision' !~ '^[1-9][0-9]{0,8}$' then raise exception 'Invalid integration message'; end if;
 kind_name=message->>'kind';external_key=message->>'externalId';year_text=message->>'period';rev=(message->>'revision')::integer;v=message->'payload';
 if kind_name not in ('Competition','Performance summary','Annual report','Funding request','Travel abroad','MRA clearance','Other request','Award nomination') or coalesce(length(external_key),0) not between 1 and 120 or year_text !~ '^(20)[0-9]{2}$' or year_text not between '2024' and '2100' or jsonb_typeof(v)<>'object' then raise exception 'Invalid message kind, ID, year or payload'; end if;
 if kind_name='Competition' then
  if coalesce(length(trim(v->>'name')),0) not between 1 and 160 or coalesce(v->>'startDate','') !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(v->>'endDate','') !~ '^\d{4}-\d{2}-\d{2}$' or (v->>'endDate')::date<(v->>'startDate')::date then raise exception 'Competition needs a name and valid dates'; end if;
  clean=jsonb_build_object('name',v->>'name','startDate',v->>'startDate','endDate',v->>'endDate','discipline',coalesce(v->>'discipline','Darts'),'category',coalesce(v->>'category','Open'),'level',coalesce(v->>'level','National'),'venue',left(coalesce(v->>'venue',''),160),'description',left(coalesce(v->>'description',''),2000));
 elsif kind_name='Performance summary' then
  select * into comp from public.association_exchange where connector_id=c.id and kind='Competition' and external_id=v->>'competitionExternalId' and published_payload is not null;
  if comp.id is null or comp.period<>year_text then raise exception 'Send the matching competition and obtain council acceptance before sharing performance'; end if;
  clean=jsonb_build_object('competitionExternalId',comp.external_id,'competitionName',comp.published_payload->>'name','season',year_text,'rankingRule',left(coalesce(v->>'rankingRule','Association-reported performance'),500));
  foreach field in array array['teams','athletes','fixtures','completedFixtures'] loop
   if coalesce(v->>field,'') !~ '^[0-9]{1,7}$' then raise exception 'Summary counts must be nonnegative whole numbers'; end if;
   clean=clean||jsonb_build_object(field,(v->>field)::integer);
  end loop;
  if (v->>'completedFixtures')::integer>(v->>'fixtures')::integer then raise exception 'Completed fixtures cannot exceed scheduled fixtures'; end if;
  if coalesce(v->'leaders','[]')<>'[]'::jsonb then
   if coalesce(v->>'publicConsent','')<>'true' or jsonb_typeof(v->'leaders')<>'array' or jsonb_array_length(v->'leaders')>50 then raise exception 'Named leaders need confirmed public permission and at most 50 rows'; end if;
   for entry in select value from jsonb_array_elements(v->'leaders') loop
    if coalesce(length(trim(entry->>'name')),0) not between 1 and 160 or coalesce(entry->>'rank','') !~ '^[1-9][0-9]{0,6}$' then raise exception 'Invalid leader name or rank'; end if;
    leaders=leaders||jsonb_build_array(jsonb_build_object('name',entry->>'name','rank',(entry->>'rank')::integer,'singlesWins',coalesce((entry->>'singlesWins')::integer,0),'doublesWins',coalesce((entry->>'doublesWins')::integer,0),'legDifference',coalesce((entry->>'legDifference')::integer,0),'c180',coalesce((entry->>'c180')::integer,0),'c177',coalesce((entry->>'c177')::integer,0),'highOuts',coalesce((entry->>'highOuts')::integer,0)));
   end loop;
  end if;
  clean=clean||jsonb_build_object('leaders',leaders,'publicConsent',leaders<>'[]'::jsonb,'recordSource','Association-reported');
 else
  if kind_name='Award nomination' then
   if coalesce(length(trim(v->>'nomineeName')),0) not between 1 and 160 or coalesce(v->>'categoryId','') not in ('junior-male','junior-female','national-team','association','development-programme','sportsman','sportswoman','disability-male','disability-female','coach','administrator','journalist-print','journalist-electronic') or coalesce(length(trim(v->>'description')),0) not between 1 and 2000 or coalesce(length(trim(v->>'motivation')),0) not between 1 and 12000 then raise exception 'Complete the nomination category, nominee, description and justification'; end if;
   clean=jsonb_build_object('categoryId',v->>'categoryId','nomineeName',v->>'nomineeName','description',v->>'description','motivation',v->>'motivation','dateOfBirth',coalesce(v->>'dateOfBirth',''));
  else
   if coalesce(length(trim(v->>'title')),0) not between 1 and 160 or coalesce(length(trim(v->>'summary')),0) not between 1 and 12000 then raise exception 'Add a title and explanation'; end if;
   clean=jsonb_build_object('title',v->>'title','summary',v->>'summary');
   if kind_name='Funding request' then
    if coalesce(v->>'requestedAmount','') !~ '^[0-9]+(\.[0-9]{1,2})?$' or (v->>'requestedAmount')::numeric<=0 or coalesce(v->>'currency','') not in ('MWK','USD','EUR') then raise exception 'Funding needs a positive amount and currency'; end if;
    clean=clean||jsonb_build_object('requestedAmount',v->>'requestedAmount','currency',v->>'currency');
   elsif kind_name='Travel abroad' then
    if coalesce(length(trim(v->>'country')),0) not between 1 and 100 or coalesce(v->>'departureDate','') !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(v->>'returnDate','') !~ '^\d{4}-\d{2}-\d{2}$' or (v->>'returnDate')::date<(v->>'departureDate')::date then raise exception 'Travel needs a destination and valid dates'; end if;
    clean=clean||jsonb_build_object('country',v->>'country','departureDate',v->>'departureDate','returnDate',v->>'returnDate');
   end if;
  end if;
 end if;
 if octet_length(clean::text)>20000 then raise exception 'Shared payload is too large'; end if;
 digest=encode(sha256(convert_to(jsonb_build_object('period',year_text,'payload',clean)::text,'UTF8')),'hex');
 select * into e from public.association_exchange where connector_id=c.id and kind=kind_name and external_id=external_key;
 if e.submission_id is not null then select * into s from public.submissions where id=e.submission_id for update; end if;
 select * into e from public.association_exchange where connector_id=c.id and kind=kind_name and external_id=external_key for update;
 if e.id is not null and digest=e.payload_hash and (rev=e.revision or (rev=e.revision+1 and not (e.kind='Competition' and e.status='Returned'))) then update public.association_connectors set last_received_at=now() where id=c.id;return jsonb_build_object('id',e.id,'revision',e.revision,'status',e.status,'duplicate',true); end if;
 if rev<>coalesce(e.revision,0)+1 then raise exception 'Revision conflict; refresh receipts before retrying'; end if;
 if e.id is not null and year_text<>e.period then raise exception 'Use a new external ID for a different reporting year'; end if;
 if e.submission_id is not null and exists(select 1 from public.submissions where id=e.submission_id and status in ('Submitted','Approved')) then raise exception 'This dossier is with council; finish its review before sending a correction'; end if;
 key=coalesce(e.id,gen_random_uuid());
 insert into public.association_exchange(id,connector_id,association_id,kind,external_id,revision,period,payload,payload_hash,source_url,status,history)
 values(key,c.id,c.association_id,kind_name,external_key,rev,year_text,clean,digest,c.site_url,case when kind_name='Competition' then 'Submitted' when kind_name='Performance summary' then 'Received' else 'Ready to complete' end,jsonb_build_array(jsonb_build_object('action','Received','revision',rev,'at',now())))
 on conflict(id) do update set revision=rev,payload=clean,payload_hash=digest,source_url=c.site_url,status=case when kind_name='Competition' then 'Submitted' when kind_name='Performance summary' then 'Received' when e.submission_id is not null then e.status else 'Ready to complete' end,review_comment='',updated_at=now(),history=association_exchange.history||jsonb_build_array(jsonb_build_object('action','Updated from association','revision',rev,'previousPayload',association_exchange.payload,'at',now()));
 if kind_name in ('Funding request','Travel abroad','MRA clearance','Other request') then
  if e.submission_id is null then
   insert into public.submissions(association_id,created_by,kind,period,payload,status,history)
   values(c.association_id,c.created_by,kind_name,year_text,clean||jsonb_build_object('sourceIntegrationId',key),'Submitted',jsonb_build_array(jsonb_build_object('action','Submitted from association site','connector',c.id,'at',now())));
  else
   update public.submissions set payload=clean||jsonb_build_object('sourceIntegrationId',key),status='Submitted',review_comment='',history=history||jsonb_build_array(jsonb_build_object('action','Correction from association site','previousPayload',payload,'connector',c.id,'at',now())) where id=e.submission_id;
  end if;
 end if;
 update public.association_connectors set last_received_at=now() where id=c.id;
 return jsonb_build_object('id',key,'revision',rev,'status',(select status from public.association_exchange where id=key),'duplicate',false);
end $$;
revoke all on function public.receive_association_message(uuid,text,jsonb) from public;
grant execute on function public.receive_association_message(uuid,text,jsonb) to anon,authenticated,service_role;

drop function if exists public.review_shared_competition(uuid,text,text);
create or replace function public.review_shared_competition(message_id uuid,decision text,comment text,expected_revision integer) returns void language plpgsql security definer set search_path=public as $$
declare e public.association_exchange;
begin
 if not public.is_reviewer() then raise exception 'MNCS reviewer required'; end if;
 select * into e from public.association_exchange where id=message_id for update;
 if e.revision is distinct from expected_revision then raise exception 'Competition changed; refresh and review the latest revision'; end if;
 if e.id is null or e.kind<>'Competition' or e.status<>'Submitted' or decision not in ('Approved','Returned') or coalesce(length(comment),0)>3000 or (decision='Returned' and coalesce(length(trim(comment)),0)=0) then raise exception 'Choose an awaiting competition and a valid decision/comment'; end if;
 update public.association_exchange set status=decision,review_comment=coalesce(comment,''),published_payload=case when decision='Approved' then payload else published_payload end,updated_at=now(),history=history||jsonb_build_array(jsonb_build_object('action',decision,'actor',auth.uid(),'comment',comment,'at',now(),'revision',revision)) where id=e.id;
 if decision='Approved' then
  insert into public.registry(collection,id,payload) values('events','exchange-'||e.id::text,e.payload||jsonb_build_object('id','exchange-'||e.id::text,'associationId',e.association_id,'type',e.payload->>'discipline','status','Approved','sourceUrl',e.source_url,'recordSource','MNCS-accepted association competition','sourceRevision',e.revision)) on conflict(collection,id) do update set payload=excluded.payload;
 end if;
end $$;
revoke all on function public.review_shared_competition(uuid,text,text,integer) from public,anon;
grant execute on function public.review_shared_competition(uuid,text,text,integer) to authenticated;

create or replace function public.public_performance_summaries() returns setof jsonb language sql stable security definer set search_path=public as $$
 select jsonb_build_object('associationId',association_id,'year',period,'sourceUrl',source_url,'updatedAt',updated_at,'payload',payload) from public.association_exchange where kind='Performance summary' order by updated_at desc;
$$;
revoke all on function public.public_performance_summaries() from public;
grant execute on function public.public_performance_summaries() to anon,authenticated;

create or replace function public.link_exchange_submission() returns trigger language plpgsql security definer set search_path=public as $$
declare e public.association_exchange;
begin
 if tg_op='UPDATE' and coalesce(old.payload->>'sourceIntegrationId','')<>'' and new.payload->>'sourceIntegrationId' is distinct from old.payload->>'sourceIntegrationId' then raise exception 'An imported dossier retains its source link'; end if;
 if coalesce(new.payload->>'sourceIntegrationId','')='' then return new; end if;
 select * into e from public.association_exchange where id=(new.payload->>'sourceIntegrationId')::uuid for update;
 if e.id is null or e.association_id<>new.association_id or e.kind<>new.kind or e.period<>new.period or (e.submission_id is not null and e.submission_id<>new.id) then raise exception 'The imported case must match your association, kind and year and can create only one dossier'; end if;
 if e.kind='Award nomination' and new.payload->>'categoryId' is distinct from e.payload->>'categoryId' then raise exception 'Keep the imported award category; use a separate nomination for another category'; end if;
 update public.association_exchange set submission_id=new.id,status=new.status,review_comment=coalesce(new.review_comment,''),updated_at=now(),history=history||jsonb_build_array(jsonb_build_object('action','Dossier '||new.status,'submissionId',new.id,'at',now())) where id=e.id;
 return new;
end $$;
revoke all on function public.link_exchange_submission() from public,anon,authenticated;
drop trigger if exists link_exchange_submission on public.submissions;
create trigger link_exchange_submission after insert or update on public.submissions for each row execute function public.link_exchange_submission();
