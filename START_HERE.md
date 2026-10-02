# MNCS Registry V0.9 — start here

Your working accounts and association submissions remain in place. This complete
release adds Sports operations, Rankings and linked awards nominations.

## Upgrade

1. Back up/export your current Supabase data.
2. In project `owvuayretqnibwwhonch`, open SQL Editor and run
   **supabase/INSTALL_ALL.sql**. Run this one complete file, not every migration.
3. Replace your Git-connected Netlify repository files with this package.
   Keep index.html at the root and netlify/functions intact.
4. Redeploy. Retain the working SUPABASE_URL, SUPABASE_SECRET_KEY and SITE_ORIGIN
   Functions settings. Keep the private key secret. If needed, retain the
   targeted SECRETS_SCAN_OMIT_KEYS=SUPABASE_URL Build setting; see
   NETLIFY_DEPLOYMENT_FIX.md. No build command or new private credentials needed.
5. Sign in with your existing account. Do not repeat initial-administrator setup.

## First sports workflow

1. MNCS admin → Rankings → create the sport's agreed placing-points rule.
2. Association → Sports operations → register athletes and/or teams; save and submit.
3. MNCS reviewer/admin → Sports operations → approve those records.
4. Association → create a competition with matching discipline/category and rule;
   submit it; MNCS approves it.
5. Association → enter fixtures/results; submit them; MNCS approves them.
6. Public Players, Events, Results and the fixture calendar now display the
   approved public records. Birth dates remain private.
7. MNCS → Rankings → inspect points, counting competitions and shared ties.
8. MNCS admin → Awards → choose year, set the junior age reference date and open
   the nomination window. New nomination windows default to Closed.
9. Association → Rankings → Prepare nomination, or Awards → choose an athlete
   and Fill verified athlete details and achievements. Review the text and attach
   the official evidence PDF; save, then submit through Workspace → Submissions.

## Read before official use

- **V0.9_RELEASE.md**: ranking rules, deployment, permissions and implemented scope.
- **V0.9_TEST_REPORT.md**: local PostgreSQL/DOM checks and required live checks.
- **demo.html**: isolated role walkthrough, fictional accounts, resets on reload.

Rankings compare athletes within the same scoring rule/discipline/category/season.
They are not awards decisions. Junior awards remain strictly under 20 on the
configured reference date. Judge ballots, public polls and official audited award
results are not implemented. Any judges-only amendment must be approved and
publicly disclosed; fan participation must never be presented as affecting
official results when its weight is zero.
