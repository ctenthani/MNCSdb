# MNCS Players & Associations Database

**First draft** of a central registry for the **Malawi National Council of Sports (MNCS)**.

This static web application captures:

- Affiliated national sports associations
- Registered players / athletes (sample data across associations)
- Events and competitions
- Competition results

## Features

- Dashboard with key counts and featured content
- Searchable & filterable Associations list
- Players registry with filters (association, gender, national team)
- Events calendar-style list with status filters
- Results table linked to players and events
- Detail modals for players, associations and events
- Fully client-side — no backend required for this draft
- Ready for Netlify deployment

## Sample Data Included

- **25** national sports associations (drawn from MNCS / MOC public lists and news reports)
- **68** sample players across those associations (mix of real well-known names and realistic placeholders)
- **15** sample events
- **15** sample results

> Note: Player and official names are illustrative for demonstration purposes. Contact details are fictional.

## Deploy to Netlify

### Option A — Drag & Drop
1. Zip the entire contents of this folder (or use the provided zip).
2. Go to [https://app.netlify.com/drop](https://app.netlify.com/drop)
3. Drop the zip or the folder.
4. Your site will be live in seconds.

### Option B — Git + Netlify
1. Push this folder to a GitHub/GitLab repository.
2. In Netlify: **Add new site → Import an existing project**.
3. Select the repo. Build settings can stay empty (static site).
4. Deploy.

### Option C — Netlify CLI
```bash
npm install -g netlify-cli
netlify deploy --dir=. --prod
```

## Local Development

Because the app loads JSON via `fetch()`, you need a local server:

```bash
# Python
python -m http.server 8080

# or Node
npx serve .
```

Then open `http://localhost:8080`.

## Project Structure

```
mncs-players-db/
├── index.html          # Main application
├── css/styles.css
├── js/app.js
├── data/
│   ├── associations.json
│   ├── players.json
│   ├── events.json
│   └── results.json
├── netlify.toml        # Optional Netlify config
└── README.md
```

## Next Steps (Future Iterations)

- Connect to a real backend (Supabase / PocketBase / custom API)
- Authentication for association secretaries and MNCS staff
- Player registration forms & document uploads
- Full event entry & results verification workflow
- Compliance dashboard (AGM dates, strategic plans, funding eligibility)
- Export / reporting (PDF, Excel)
- Mobile app or Progressive Web App enhancements

---

**Malawi National Council of Sports**  
Draft prepared for demonstration and further development.

## v0.2 setup

The Workspace includes association drafts, PDF submissions and MNCS review.
Without configuration it runs an explicitly labelled, in-memory workflow preview.
Preview roles are not authentication and must never be used with real records.

1. Create a Supabase project and run `supabase/schema.sql` in its SQL editor.
2. Create users through Supabase Authentication, then provision `profiles` rows
   using a trusted administrator connection. Association accounts require an
   association ID matching a row in `registry`. Users cannot change their roles.
3. Seed `registry` with verified records, using `collection`, `id` and `payload`.
   Do not seed the included demonstration names/results as verified facts.
   Public payloads must omit phone numbers, birth dates, private email addresses,
   identification documents and other private data. Athlete registration is
   not implemented in this release.
4. Set the project URL and public publishable/anon key in `js/config.js`.
   Never put a service-role key in the repository or browser.
5. Deploy through the existing Netlify integration after reviewing a branch preview.
6. Test with two different association accounts and a reviewer before production:
   association A must not read B's submissions or documents, edit roles, approve
   records or write public registry data. Anonymous users must not read submissions.

The PDF bucket is private with a 10 MB size limit. Signed links expire in 60 seconds.
The database records review transitions and locks status changes inside a transaction.
Approval publishes selected association profile fields only, keeping contacts private.
In v0.3, returned records are corrected in place and retain their review history.
Public athlete details omit phone numbers and birth dates, including from sample files.
Event date status is computed in Africa/Blantyre: Past does not certify completion.

Funding, payments, account invitation UI, athlete editing and rankings are deferred.
Account provisioning and initial verified association creation require a trusted
Supabase administrator. Database policies require live integration testing; static
checks alone cannot establish production security.

Run checks: `node --test tests/registry.test.cjs`.

## v0.3

Editable drafts/returned records retain their history and can replace supporting PDFs.
MNCS reviewers can configure reporting requirements with deadlines, then export a
management CSV showing Missing, Draft, Submitted, Returned and Approved records.
See `SUPABASE_SETUP.md` for the full setup, including the additional migration.
The supplied project URL and public publishable key are configured. Run the database migrations and provision accounts before live use.

## v0.4: on-site accounts

Initial MNCS administrator setup, MNCS/association account creation, association
registration and password changes now happen in Workspace. See `ACCOUNT_SETUP.md`
for the one-time migration and server configuration. Deploy through Git so the
Netlify function is built. This feature is implemented but requires live setup
and permission testing before use.

Run all checks: `node --test tests/*.cjs tests/*.mjs`.

## v0.5: Malawi Sport Awards

Adds the 14 handbook categories and association nomination dossiers. Read
`AWARDS_IMPLEMENTATION.md`, then run `supabase/v0.5-migration.sql` once after v0.4.
Official judging, voting and rankings are not yet enabled; the isolated scoring
helper requires explicitly approved normalization and certified vote inputs.

## Latest v0.6 installation

Start with `START_HERE.md` and run only `supabase/INSTALL_ALL.sql`. It includes all
implemented database versions. Junior candidates must be under 20 on an explicit
cycle reference date. Judges-only awards are an openly disclosed proposed policy
amendment, not a hidden removal of the handbook public-vote component.

## v0.6.1 sign-in recovery

Users created manually in Supabase Auth may lack a profiles row. The app now
shows Account setup incomplete and a Sign out button instead of a blank workspace.
For the project owner only, `supabase/RECOVER_FIRST_ADMIN.sql` can repair the first
admin profile for a specified existing Auth account. It refuses to overwrite a
profile, bypass a pending bootstrap, or create another admin when one exists.
Do not add this recovery query to normal installation or public signup.

## v0.6.2 workspace and association registration

See V0.6.2_UPDATE.md for the updated registration flow, signed-in workspace and installation instructions. Run the latest supabase/INSTALL_ALL.sql before using association registration.
