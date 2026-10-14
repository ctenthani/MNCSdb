# Automatic association statistics

MNCS Performance reads current aggregate totals from configured public feeds when opened and refreshes every five minutes while the view is visible. These reads do not submit nominations, approve competitions, write council dossiers or change official results. Saved summaries remain available during failures and are explicitly labelled as not refreshed.

## Darts Malawi

The server rechecks enabled association connections and council-approved competitions, then reads the fixed Dartsmw published regional results endpoints. It counts registered teams/athletes, scheduled fixtures excluding byes, and completed fixture-linked results. Unknown website URLs are never fetched. A paused connection cannot expose cached Darts stats.

## TESSAM

Install `tessam/public-stats.sql` only in TESSAM's Supabase project, not the MNCS database. The public RPC exposes competition metadata and aggregate totals for registered teams, registrar-certified athletes, scheduled fixtures and GS-approved results. TEST competitions and provisional scores are excluded. Student names, numbers, birth dates and contact details are never returned. This does not require redeploying the manually uploaded TESSAM website or sharing its private service-role key.

The adapter maps TESSAM to the existing national registry entry RESEARCH-28. Displaying association totals does not certify affiliation or replace council competition approval. The configured publishable key is browser-safe; it is not a secret or service-role credential. No private keys belong in this source.

## Freshness and limits

The server cache lasts 60 seconds. A failed source can retain a verified cache entry for up to one day in the same function process, marked stale; a cold process may have no previous entry and falls back to saved council summaries in the UI. Fetch timestamps are labelled as fetches, not dates when associations last entered results. There is no unattended database copying or scheduled submission of reports. No cross-sport athlete ranking is produced. New association sites require explicit adapters to their public aggregate feeds rather than arbitrary URL scraping.
