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
