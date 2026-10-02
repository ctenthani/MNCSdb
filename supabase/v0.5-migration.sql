-- Run once after v0.4. Draft award nominations use the private submission workflow.
alter table public.submissions drop constraint submissions_kind_check;
alter table public.submissions add constraint submissions_kind_check check(kind in ('Profile update','Constitution','AGM minutes','Strategic plan','Annual report','Award nomination'));
drop index public.unique_current_submission;
create unique index unique_current_submission on public.submissions(association_id,kind,period) where status in ('Draft','Submitted','Approved') and kind<>'Award nomination';
create unique index unique_award_nomination on public.submissions(association_id,period,(payload->>'categoryId'),lower(trim(payload->>'nomineeName'))) where kind='Award nomination' and status in ('Draft','Submitted','Approved');
alter table public.submissions add constraint nomination_shape check(kind<>'Award nomination' or (
 period ~ '^[0-9]{4}$' and period between '2024' and '2100'
 and coalesce(payload->>'categoryId','') in ('junior-male','junior-female','national-team','association','development-programme','sportsman','sportswoman','disability-male','disability-female','coach','administrator','journalist-print','journalist-electronic')
 and length(trim(coalesce(payload->>'nomineeName',''))) between 1 and 160
 and length(trim(coalesce(payload->>'description',''))) between 1 and 2000
 and length(trim(coalesce(payload->>'motivation',''))) between 1 and 12000
 and coalesce(payload->>'declaration','')='true'
 and document_path is not null
));
-- Approval in submissions denotes dossier screening only, never a category win.
