-- Allow signed-in MNCS administrators to register associations from the site.
-- Other roles cannot insert registry records. Initial registration contains
-- public association details only; document review remains a separate workflow.
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
