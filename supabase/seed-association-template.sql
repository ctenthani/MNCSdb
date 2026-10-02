-- Replace these placeholders with verified association information.
-- Stable IDs must match the association_id in the account profile.
insert into public.registry(collection,id,payload) values (
 'associations','YOUR_ASSOCIATION_ID',
 jsonb_build_object('id','YOUR_ASSOCIATION_ID','name','Verified association name',
 'shortName','SHORT_NAME','sport','Sport name','status','Under Review',
 'verificationStatus','Verified registry entry','strategicPlan',false)
);
-- After creating the corresponding Authentication users, copy their actual UUIDs:
-- insert into public.profiles(id,role,association_id)
-- values ('ACTUAL_AUTH_USER_UUID','association','YOUR_ASSOCIATION_ID');
-- insert into public.profiles(id,role,association_id)
-- values ('ACTUAL_MNCS_AUTH_USER_UUID','admin',null);
