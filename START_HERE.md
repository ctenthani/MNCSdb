# MNCS Registry V1.0 — start here

This complete package simplifies the working portal. Each association saves its
own athletes, teams, fixtures and results directly. Only competitions go to MNCS
for approval. Reports, awards nominations and requests have a separate council inbox.

## Upgrade your existing portal

1. Export a backup of your Supabase data.
2. In project `owvuayretqnibwwhonch`, open SQL Editor and run
   **supabase/INSTALL_ALL.sql** once. This file contains all required migrations.
3. Replace the files in your Git-connected Netlify repository with this package.
   Keep index.html at the root and netlify/functions intact. Redeploy.
4. Retain the working SUPABASE_URL, SUPABASE_SECRET_KEY and SITE_ORIGIN settings.
   Keep private keys in Functions settings. Retain the targeted
   SECRETS_SCAN_OMIT_KEYS=SUPABASE_URL setting if needed; do not disable secret scanning.
5. Sign in with your existing account. Do not repeat initial administrator setup.
6. Check the account name, email, role and association shown below the navigation.

## Association: manage your sport

1. Open Workspace → Manage my sport. Add an athlete or team and click Save.
   Choose public permission explicitly; birth dates stay private.
2. Add your competition; save the draft and click Submit to MNCS.
3. After council accepts the competition, save fixtures and results directly.
4. For a team tournament, open Competitions → Automatic tournament planner.
   Choose teams and generate round-robin or knockout fixtures.
5. For knockout fixtures, record the winning team's result in Results, then
   choose that team and click Advance winner in the tournament.
6. Open Rankings to set your sport's placing points and view its leaderboard.
7. Open Council requests & reports for an annual report, funding request,
   travel abroad, MRA clearance or another request. Save, then submit to council.
8. Open Awards and click a category. Its nomination form is selected for you.
   Fill athlete achievements from your records, add your justification and PDF,
   save the draft, then submit through Council requests & reports.

## MNCS: start an awards cycle

1. Create judge and independent auditor accounts in Account management.
2. Open Awards. Set the year and the junior age reference date; junior nominees
   must be strictly under 20 on that date. Open nominations when ready.
3. Select judges-only scoring and record that MNCS approved and publicly
   disclosed this amendment. The handbook's original public weighting differs.
4. Review nomination eligibility in the council inbox. Click a category in Awards.
5. Approve its criterion weights (total 100%) and judge count; normally five.
   Add up to three eligible finalists with confirmed public consent. Assign judges
   and an independent auditor. Resolve conflicts before opening judging.
6. Open judging. Each judge signs in, reads evidence and seals a ballot for each
   finalist. Marks are 0–10 per criterion. Other judges' marks remain hidden.
7. MNCS may open a separate fan poll. It has ZERO effect on official scores.
8. Close judging when all assigned ballots are complete. The auditor signs in,
   reviews/downloads confidential records, independently checks them and certifies.
9. Close the fan poll, then publish certified official results. Equal judge totals
   share rank; the public sees official scores and the audit fingerprint.

## Enable email verification for public polls

Staff accounts continue to be created on the site by MNCS. Fans use verified email.
In Supabase Authentication settings, enable the Email provider and new-user signups
for fans; configure production SMTP. Set Site URL to `https://mncsdb.netlify.app`
and allow the production `/index.html` redirect. In the Magic Link email template,
include the verification code `{{ .Token }}` (you may retain its sign-in link).
Test receipt and verification using an email you control before opening a poll.
Email signup grants only the fan role; it cannot grant MNCS or association access.
Supabase email quotas, rate limits and SMTP delivery still apply.

Read **V1.0_RELEASE.md** and **V1.0_TEST_REPORT.md** for limits and verification.
The offline demo is a basic walkthrough; ballots, polls and tournaments use the
connected database. This package has been tested locally and is not deployed yet.
