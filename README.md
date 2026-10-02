# MNCS Registry — V1.0

A registry and reviewed sports operations portal for Malawi National Council of
Sports and association representatives. Read **START_HERE.md** first.

## Implemented

- Public registry with consented athlete profiles and association-reported results.
- On-site account management; persistent signed-in account identification.
- Association-owned athletes, teams, fixtures/results; council-reviewed competitions.
- Private annual reports, nominations and funding/travel/clearance/other requests.
- Association performance rankings and CSV exports.
- Clickable award categories, strictly under-20 eligibility and linked dossiers.
- Sealed judge ballots, independent certification and fingerprinted official results.
- Separate verified-email fan polls with zero effect on official scores.
- Round-robin and knockout tournament generation and winner progression.

The frontend is shipped static HTML/CSS/JavaScript with local assets. Supabase
provides authentication, private tables, RLS, transactions and document storage.
Netlify Functions provides privileged account operations. A static-only drag/drop
deployment cannot provision that account service.

No npm build is required to deploy. netlify.toml publishes the repository root.
Use a Git-connected Netlify deployment and preserve netlify/functions.

## Database

Run **supabase/INSTALL_ALL.sql** as the single transactional installer for a new
project or an upgrade from the earlier project schemas. It includes V1.0 and
preserves existing accounts, records and setup state. Back up data before upgrading.
The versioned SQL files remain as source/history; do not run them all separately.

Only the public Supabase URL/publishable key belong in js/config.js. Private keys
belong in Netlify Functions environment settings. NETLIFY_DEPLOYMENT_FIX.md covers
the public URL's secrets-scanner false positive without disabling private-key scans.

## Development and tests

    node --test tests/*.cjs tests/*.mjs
    python scripts/build_installer.py
    python scripts/build-demo.py

For the optional actual PostgreSQL and DOM integration tests, install
@electric-sql/pglite@0.3.14 and jsdom in your local test environment, then set
PGLITE_MODULE to its absolute dist/index.js and JSDOM_MODULE to jsdom's absolute
package directory. Without those paths, integration tests report skips.
Tailwind 3.4.17 rebuilding instructions remain in V0.8_RELEASE.md; compiled CSS is shipped.

demo.html uses an in-memory simulator and fictional admin/reviewer/association
accounts with password 1234. It calls neither live Supabase nor the account service.
Demo changes reset on reload; confidential awards and tournament operations require
the connected portal. The simulator is not a database security test.

V1.0_RELEASE.md documents ranking conventions and limits. V1.0_TEST_REPORT.md
distinguishes local verification from live deployment. Automatic league standings and advanced bracket rollback remain future work.

The data/ sample files remain historical demonstration content, never a fallback
for missing live data. Sourced association candidates retain their provenance;
they are not automatically certified MNCS affiliations.
