# MNCS Registry — V1.1

MNCSdb is the national registry and council oversight portal. Associations use their own sites for players, teams, fixtures, results and tournaments. Read **START_HERE.md** to upgrade, then **integrations/darts/README.md** to connect the Darts pilot.

## What changes

- Association sites panel with administrator-issued, revocable connections.
- Competitions shared by associations and reviewed by council.
- Association performance summaries derived from published results; no individual fixture or result approval.
- Private annual reports, awards nominations and funding, travel, clearance and other requests.
- Decisions and comments returned to the association site through receipts.
- Existing on-site accounts, clickable awards categories, under-20 eligibility, sealed ballots and audited results remain available.
- Public fan polls remain separate from official judge scores.

The default workspace is now national oversight. Existing operational records are preserved; daily management panels are removed from the default navigation. Associations without a connected site can still submit competitions, reports, nominations and requests directly.

## Deployment

Static HTML/CSS/JavaScript, Supabase authentication/database/storage and Netlify Functions. No npm build is required. Deploy through a Git-connected Netlify project so Functions are bundled. Run **supabase/INSTALL_ALL.sql** once for a new installation or an upgrade; it includes all migrations through V1.1. Existing accounts and records are retained.

Private Supabase and connector keys belong only in server environment settings. The Darts addon is a merge package, not a replacement Darts website.

## Verification

    python scripts/build_installer.py
    python scripts/build-demo.py
    node --test tests/*.cjs tests/*.mjs

Actual PostgreSQL and DOM tests require @electric-sql/pglite@0.3.14 and jsdom@26. Set PGLITE_MODULE to its absolute dist/index.js and JSDOM_MODULE to the jsdom package directory; otherwise those tests report skips. Compiled local Tailwind CSS is shipped.

See **V1.1_TEST_REPORT.md** for the tested scope and **V1.1_RELEASE.md** for limits. The offline demo uses fictional accounts and password 1234; it is not connected to production and does not simulate connector authorization.
