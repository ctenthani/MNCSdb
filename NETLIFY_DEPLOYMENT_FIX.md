# MNCS V0.8 deployment fix

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
