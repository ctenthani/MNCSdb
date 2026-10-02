# MNCS Registry V1.1 — start here

MNCSdb now handles the national register and council work. Association sites handle sport operations. Darts Malawi is the first connector pilot.

## Upgrade MNCSdb

1. Back up your Supabase data and current site files.
2. In Supabase project `owvuayretqnibwwhonch`, open SQL Editor and run **supabase/INSTALL_ALL.sql** once. This complete transactional file includes every required migration through V1.1. Do not run the versioned files separately.
3. Replace the files in your existing Git-connected MNCSdb Netlify repository with this package. Keep index.html at the root and netlify/functions intact. Redeploy through Git, with Functions enabled.
4. Retain the working SUPABASE_URL, SUPABASE_SECRET_KEY and SITE_ORIGIN environment settings. Private keys belong in Functions settings. Retain SECRETS_SCAN_OMIT_KEYS=SUPABASE_URL if needed for the public URL false positive; do not disable secret scanning.
5. Sign in with your existing MNCS administrator account. Do not repeat first-administrator setup.
6. Check Workspace → Association sites. Select the correct registered Darts association, enter `https://dartsmw.netlify.app/`, and create its connection. The researched Darts candidate is not automatically treated as affiliated.
7. Copy the connection ID and one-time token privately into the Darts site's Functions environment settings, following **integrations/darts/README.md**. Do not put the token into browser JavaScript, Git or chat.

## Pilot flow

1. Install the addon into the existing Darts source and deploy the whole Darts project, retaining its current results function.
2. Sign in on Darts using its existing site administrator login. Open its new MNCS tab.
3. Select a regional league or competition, complete its dates and send it to MNCS.
4. MNCS reviews it in Workspace → Competitions. Darts retrieves the decision and comments when receipts are refreshed.
5. After acceptance, preview and share the regional league performance summary. Player names are excluded unless explicitly selected for public sharing. Individual results remain managed by Darts.
6. Funding, travel, MRA clearance and other completed requests enter the private council inbox directly.
7. Reports and nominations arrive as private drafts. An association representative signs into MNCSdb, opens Incoming drafts, attaches the required PDF and submits. Junior nominees must be strictly under 20 under the existing eligibility rules.
8. MNCS manages the awards cycle, judges and certification centrally. Public poll participation cannot change official judge scores.

The first pilot reads the current 2026 Darts league only. See the connector README for ranking rules and source limits. This is a manual share/refresh pilot; it does not yet run a scheduled background sync or provide a shared login.

## Deployment status

The package was tested locally. It has not been deployed to your live sites. The Darts Netlify project link returned Access Denied and did not provide its source. To finish the Darts deployment, use the original Darts repository or current complete source ZIP. Do not upload the addon ZIP as a standalone replacement website.
