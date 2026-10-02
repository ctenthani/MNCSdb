# MNCS v0.4: create all accounts on the site

Routine account creation now happens in Workspace. Supabase continues to store
and authenticate the accounts; users do not need Supabase dashboard access.

## One-time installation by the site owner

1. If v0.3 is not installed, first run its migration as described in
   `SUPABASE_SETUP.md`. Then run `supabase/v0.4-migration.sql` once in SQL Editor.
   Do not rerun previous migrations.
2. Deploy this complete project through the Git-connected Netlify site so
   Netlify builds `netlify/functions/accounts.mjs`. A static drag-and-drop upload
   alone does not deploy the account function. Existing account/profile records
   are preserved.
3. In Netlify's environment variables, add the following, available to Functions:

   | Variable | Value |
   |---|---|
   | `SUPABASE_URL` | `https://owvuayretqnibwwhonch.supabase.co` |
   | `SUPABASE_SECRET_KEY` | Your project's private secret key (`sb_secret_…`), or legacy service-role key |
   | `SITE_ORIGIN` | `https://mncsdb.netlify.app` — no trailing slash |
   | `MNCS_SETUP_CODE` | A privately generated random code of at least 32 characters |

   Add these directly in Netlify. Never put the private key or setup code in
   GitHub, frontend configuration, screenshots or chat. Trigger a fresh deploy
   after saving the variables. Each preview domain needs its own exact
   `SITE_ORIGIN` if you choose to test a branch preview.
4. Keep public self-signup disabled in Supabase Authentication. Account creation
   uses the server's administrator API, not anonymous browser signup. Account
   emails are marked confirmed by the administrator; ownership is verified
   operationally by MNCS, not by an automated confirmation email in this release.
5. Open the site → Workspace → **Set up the initial MNCS administrator**.
   Enter your name, email, chosen password (at least 12 characters), confirmation,
   and the private setup code. This creates the Auth user and admin profile.
   Sign in with the new email/password.
6. Remove `MNCS_SETUP_CODE` from Netlify and redeploy after initial setup.
   The database already locks setup after success. If an administrator already
   exists, initial setup is refused; use that account instead.

## Normal operation on the site

1. Sign in as an MNCS administrator.
2. Under Account management, register an association if it is not already listed.
   The new registry entry is labelled Under Review, not verified affiliation.
3. Create an account with the person's name, email and initial password.
4. Select MNCS administrator, MNCS reviewer or Association administrator. For an
   association account select its association. Multiple accounts can belong to
   the same association.
5. Provide the initial credentials privately to the intended person. They can
   use Change my password in Workspace. This release does not automatically send
   invitations or implement forgotten-password recovery.

MNCS reviewers and association accounts cannot create accounts or choose new
roles. The server verifies the login token and current admin profile on each
request. Passwords are sent over HTTPS to the account service and Auth only;
passwords are not written to the profiles table or logged by the handler.

## Verify before production

Test initial setup twice (the second attempt must fail); account creation as an
administrator; rejection as a reviewer/association/anonymous caller; association
membership; duplicate emails; and a password change followed by sign-out/sign-in.
Also repeat the v0.3 document isolation checks. Local tests cannot certify the
live Netlify environment, Supabase grants or policies.

If a deployment/network failure interrupts initial setup, inspect
`initial_admin_setup`, Auth users and profiles in Supabase before retrying. A
pending claim must not be blindly cleared: ensure no admin was created first.
This exceptional recovery is an owner task, not routine account management.
