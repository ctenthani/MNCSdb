# MNCS Registry v0.3 — Supabase integration

## New project
1. Create a project at https://supabase.com/dashboard. Keep the database password private.
2. Open SQL Editor and run `supabase/schema.sql` once.
3. Run `supabase/v0.3-migration.sql` once.
4. In Table Editor, confirm `profiles`, `registry`, `submissions` and
   `reporting_requirements` exist. In Storage, confirm `association-documents`
   is private, accepts PDFs and has the 10 MB limit.

## Existing v0.2 project
Run only `supabase/v0.3-migration.sql`. Do not rerun the original schema.
These scripts are one-time migrations, not idempotent setup commands.

## Authentication and accounts
1. Enable email/password authentication. Keep public signup disabled if accounts
   are invitation-only. This release signs in existing accounts; it has no signup,
   email-invitation acceptance or password-reset interface.
2. Set Authentication → URL Configuration → Site URL to your actual deployed
   Netlify URL, currently https://mncsdb.netlify.app/.
3. In Authentication → Users, create test users using the dashboard's supported
   user-management action. Follow its email confirmation requirements. Do not
   share passwords in chat.
4. Add a `profiles` row for each user. Its `id` must equal the Authentication
   user's UUID. Use role `admin`, `reviewer` or `association`. Association accounts
   require `association_id`; MNCS accounts can leave it null.
5. Use `seed-association-template.sql` as a template to create verified registry
   records. Its association ID must match the association account's profile.
   Replace all placeholders; do not paste the commented UUID examples unchanged.
   The supplied sample JSON must not be imported as verified national data.

## Connect the frontend
Project ID supplied: `owvuayretqnibwwhonch`. Its URL is already configured.
Obtain the publishable key from the project's Connect dialog/API
settings. Edit `js/config.js`:

```javascript
window.MNCS_CONFIG = {
  supabaseUrl: 'https://owvuayretqnibwwhonch.supabase.co',
  supabaseKey: 'YOUR_PUBLIC_PUBLISHABLE_KEY'
};
```

A legacy anon key also works. Never use a secret or service-role key in this file.
This static site reads config.js directly: setting Netlify environment variables
alone will not populate it. Deploy the changed files through your Netlify workflow.
With both settings present, sample data is replaced by the public `registry` table.
An empty registry produces empty lists; this is not a failed connection.

## Verify before real use
Use two association accounts with different IDs, one MNCS reviewer and a signed-out
browser. Check:
- Each association can save, edit and submit its own draft.
- Association A cannot read B's submissions or PDFs through the API or UI.
- An association cannot review records, add reporting requirements or change roles.
- A reviewer can add requirements, return a submission with comments and approve it.
- A returned record can be edited and resubmitted, preserving its history.
- Supporting documents require authentication and signed URLs expire.
- Approval of a profile update changes the public association profile, without
  publishing private contacts or document contents.
- Management CSV counts match the configured requirements and submission records.

Four tables and the private document bucket are protected by row-level policies.
Live access-control testing remains required; local tests cannot verify a hosted
Supabase project's configuration. Provisioning accounts and initial registry records
still requires an administrator in Supabase; on-site account creation is deferred.


## v0.4: accounts created on the site

Follow `ACCOUNT_SETUP.md` for the extra migration and Netlify server settings.
Manual Authentication user creation is no longer required for routine use.
