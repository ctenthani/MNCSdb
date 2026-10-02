# MNCS Registry V0.8 — start here

Read V0.8_RELEASE.md for the current release and deployment steps.
Read V0.8_TEST_REPORT.md for what was and was not tested.

This ZIP contains all implemented features from v0.2 through V0.8. You do not need
to deploy earlier ZIPs or run their SQL files individually.

1. Make a backup/export of existing project data before installing.
2. Open Supabase project `owvuayretqnibwwhonch` → SQL Editor.
3. Paste and run **supabase/INSTALL_ALL.sql**. Run this one file only. It imports researched association candidates marked for MNCS verification and creates
   new tables or updates the earlier app schemas, preserving records and initial
   administrator setup state. Changes run inside a transaction; if incompatible
   records cause an error, keep the error for review rather than deleting records.
4. Upload the latest project files to the Git repository linked to Netlify.
   Keep index.html at the repository root and preserve netlify/functions.
   Netlify must build the server function; a static drop upload alone is insufficient.
5. Configure these private Netlify environment variables for Functions and redeploy:
   - SUPABASE_URL: https://owvuayretqnibwwhonch.supabase.co
   - SUPABASE_SECRET_KEY: your private Supabase secret/service-role key
   - SITE_ORIGIN: https://mncsdb.netlify.app (no trailing slash)
   - MNCS_SETUP_CODE: random private code of at least 32 characters, initial setup only
   Put private keys in Netlify, never GitHub or chat. Frontend public settings are
   already configured in js/config.js.
6. If no MNCS admin exists, open Workspace → Set up the initial MNCS administrator.
   Create your account with your privately chosen email/password and setup code.
   Remove MNCS_SETUP_CODE and redeploy after success. Existing admins should sign in.
7. In Workspace, use Associations to register associations, then Create accounts to add their representatives. Association registration uses your signed-in administrator session and the new registry_admin_register database policy. Account creation still requires the Netlify function settings.
8. In Awards, use Configure an awards cycle to enter the year and junior reference
   date. The rule is under 20 on that date, not 20 or younger. 31 December of the
   qualifying year is a possible reference date, but MNCS must choose it explicitly.
9. If MNCS changes the handbook to judges-only official awards, disclose the change
   clearly before opening participation. Public fan polls must say they do not
   influence official awards. Record policy approval/disclosure in the cycle form.
10. Test two association accounts, an MNCS reviewer and an MNCS administrator.
    Check private documents/submissions are isolated and only admins create accounts.

## Current scope
Association submissions, account creation, reporting requirements, category
information and award dossier screening are implemented. Scoring helpers are
locally tested. Live judge scoring, verified public polling, official server-side
rankings, auditor sign-off and appeals are not yet implemented. Cycle settings
keep official ranking disabled; an Approved nomination is not an award win.

## Important installation limits
The full installer was checked for SQL syntax, not executed against your live
project. Live authentication, RLS, account service and document tests remain
necessary. Prior manual edits to table definitions/policies may require review.
Email invitations and forgotten-password recovery are not implemented.

## v0.7 account error, demo and password resets
Read V0.7_UPDATE.md for the SITE_ORIGIN fix, isolated pseudo accounts using 1234, sourced associations and administrator password resets.
