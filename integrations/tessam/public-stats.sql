-- Install ONLY in the Supabase project used by tessamims.netlify.app.
-- Exposes aggregate statistics, never student identities or provisional scores.
create or replace function public.mncs_public_statistics()
returns jsonb language sql stable security definer set search_path=public
as $$
 select jsonb_build_object('source','https://tessamims.netlify.app','checkedAt',now(),'summaries',coalesce(jsonb_agg(summary),'[]'::jsonb))
 from (
  select jsonb_build_object(
   'competitionId',c.id,'year',c.season,'competitionName',c.name,
   'teams',(select count(*) from teams t where t.competition_id=c.id),
   'athletes',(select count(distinct e.athlete_id) from eligibility e where e.competition_id=c.id and e.status='certified'),
   'fixtures',(select count(*) from fixtures f where f.competition_id=c.id and f.status<>'cancelled'),
   'completedFixtures',(select count(*) from fixtures f where f.competition_id=c.id and f.status='approved'),
   'rankingRule','Approved team-sport results and registrar-certified athlete totals. Provisional scores and student details are excluded.') summary
  from competitions c where c.name !~* '\mTEST\M' and c.season ~ '^[0-9]{4}$' and c.status in ('open','closed','completed')
  order by c.season desc,c.name
 ) rows;
$$;
revoke all on function public.mncs_public_statistics() from public;
grant execute on function public.mncs_public_statistics() to anon,authenticated;
notify pgrst,'reload schema';
