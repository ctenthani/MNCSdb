-- OPTIONAL RECOVERY ONLY. Does not run as part of INSTALL_ALL.sql.
-- The project owner must run this in Supabase SQL Editor, after INSTALL_ALL.sql.
-- Replace the email if the account you manually created uses a different one.
DO $$
DECLARE
 target_email text := 'ctenthani@gmail.com';
 target_id uuid;
BEGIN
 -- Serialize initial-admin recovery with the website bootstrap process.
 PERFORM 1 FROM public.initial_admin_setup WHERE id=1 FOR UPDATE;
 IF EXISTS(SELECT 1 FROM public.initial_admin_setup WHERE id=1 AND claim IS NOT NULL AND NOT completed) THEN
  RAISE EXCEPTION 'Website administrator setup is pending. Inspect its claim and Auth account before using recovery.';
 END IF;
 SELECT id INTO target_id FROM auth.users WHERE lower(email)=lower(target_email);
 IF target_id IS NULL THEN RAISE EXCEPTION 'No Authentication user exists for this email. Check Authentication > Users.'; END IF;
 IF EXISTS(SELECT 1 FROM public.profiles WHERE id=target_id) THEN
  RAISE EXCEPTION 'This user already has a profile. Inspect its role and access policies instead of overwriting it.';
 END IF;
 IF EXISTS(SELECT 1 FROM public.profiles WHERE role='admin') THEN
  RAISE EXCEPTION 'An MNCS administrator already exists. Use that administrator to provision this account.';
 END IF;
 INSERT INTO public.profiles(id,role,association_id,email,display_name)
 VALUES(target_id,'admin',null,target_email,'MNCS Administrator');
 UPDATE public.initial_admin_setup SET completed=true WHERE id=1;
 RAISE NOTICE 'MNCS administrator profile created. Sign out and sign in again with the existing account password.';
END $$;
