> Historical setup guide. For V1.1, follow **START_HERE.md** and run only
> **supabase/INSTALL_ALL.sql**. Fan polls require Email signups enabled and
> verified email; staff roles remain provisioned by MNCS on the site.

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

## Netlify deployment fix: public Supabase URL

If Netlify reports `Secret env var "SUPABASE_URL"'s value detected`, the
public project URL has been classified as a secret. It is intentionally present
in the browser configuration; it is not a password or private API key.

1. In Netlify, open your project → **Project configuration → Environment variables**.
2. Add `SECRETS_SCAN_OMIT_KEYS` with the exact value `SUPABASE_URL`. Make it
   available to Builds in the production context (and other contexts you deploy).
   Leave **Contains secret values** unchecked for this new setting.
   If this variable already exists, preserve its other reviewed exclusions and
   append `SUPABASE_URL` as a comma-separated entry.
3. Keep `SUPABASE_SECRET_KEY` marked as secret. Keep `MNCS_SETUP_CODE` secret if
   it is still needed for initial setup. Do not exclude either from scanning.
4. Save and trigger a fresh production deploy from the Deploys page.
5. Check the deploy log, open Workspace, sign in, and test account creation.
   A successful build does not itself prove the account service is configured.

Do not disable secrets scanning or exclude entire files. This setting excludes
only the public project URL. Netlify does not allow removal of an existing
secret flag; the narrow exclusion avoids deleting/recreating that setting.
For new configurations, `SUPABASE_URL` and `SITE_ORIGIN` are public settings;
only the private key and temporary setup code should be marked as secret.

No SQL, database, account or password changes are needed for this deployment fix.
The application code is unchanged from V0.8. This package only clarifies setup.

Reference: https://docs.netlify.com/build/environment-variables/secrets-controller/
