# Darts Malawi → MNCSdb connector V1.1

This addon adds an MNCS tab to the existing Darts website. It preserves app.js, the results function and existing league operations. **It is not a complete Darts website and must not replace the current deployment by itself.**

## Install

1. Upgrade MNCSdb using its complete V1.1 SQL installer and deploy its Functions.
2. In MNCSdb, sign in as administrator → Workspace → Association sites. Select the correct registered Darts association and configure `https://dartsmw.netlify.app/`. Copy the connection ID and one-time token privately.
3. Obtain the current complete Darts source. Make a backup. Its root must contain index.html and app.js.
4. Extract this addon to a separate folder. From the Darts source root, run `python /absolute/path/to/addon/install_connector.py` using Python 3.11 or later. The installer copies assets, lib and netlify/functions/mncs-connect.mjs, then adds a stylesheet and script to index.html. Existing conflicting files receive a .before-mncs backup; the original index is backed up. Repeat installation does not duplicate the tags.
5. The addon expects the standard `netlify/functions` directory. For a custom directory, adapt the function path and its relative lib import manually. The installer refuses a conflicting directory.
6. In the **Darts** Netlify project environment settings, add MNCS_CONNECTOR_ID and MNCS_CONNECTOR_TOKEN. Enable their Functions scope. Keep the token secret; do not commit it or put it in frontend config. Existing Darts backend settings remain required.
7. Commit the merged Darts project and deploy through its existing Git-connected Netlify project. Confirm the existing results function and new mncs-connect function are both bundled. A static-only drag/drop deploy is insufficient.
8. Open Darts, use its existing site administrator login, then open MNCS. Test the sequence below before wider use.

Manual alternative: copy the three addon directories into the existing project, add `<link rel="stylesheet" href="assets/mncs-connect.css">` before the closing head tag, and `<script src="assets/mncs-connect.js"></script>` after the existing app.js script and before the closing body tag. Keep the original app.js and results function.

## First exchange

Send a competition with valid dates → council approves in MNCS → refresh receipts on Darts → preview and send its performance summary. Try a funding request and confirm it appears in the council inbox. Then send an annual report or nomination, complete its PDF in MNCS as an association representative, submit, and confirm the council decision returns in Darts receipts.

The addon verifies the existing Darts login on the server for every call. A positive `role: "admin"` or `siteAdmin: true` response is required. Captain accounts are rejected. Browser flags alone do not grant access. Separate Darts and MNCS logins remain; there is no single sign-on.

## Data and rankings

- Operational players, teams, fixtures and results stay on Darts. MNCS approves competitions, receives summaries and processes council business.
- Summaries are recalculated server-side from the existing results API's saved published results. Unsaved client changes, pending collections and training caches are not used.
- The pilot supports SRDL, CRDL and NRDL **2026** league summaries. The source API has no season selector, so another year cannot be relabelled as 2026 data. Custom competitions can be submitted, but their performance summaries require a future source adapter. EGENCO and KK separate event results are not combined with league rankings.
- Ranking order: singles wins, doubles wins, combined singles and doubles leg difference, 180s, 177s, then high checkout counts. Equal metrics share rank. These are Darts-specific association rankings, not an official comparison across different sports or an awards score.
- Scheduled fixture counts come from the current Darts fixture list; completed results and achievement counts come from the server. Teams depend on saved server metadata. Athletes are identified by the source's names, so identical names and spelling changes require association review.
- Public named leaders are opt-in, limited to 50; confirm athletes' permission before selecting the option. Summaries exclude birth dates and contact details. Private nomination birth dates remain within council workflows.
- Reports and nominations are staged until a representative adds their required private PDF and submits in MNCS. Funding, travel, clearance and other requests enter the council inbox directly. Awards categories are clickable; imported nomination categories must match their final dossier.

## Reliability and control

Messages have stable external IDs and sequential revisions. Identical retries do not create another record. A changed competition needs a new review; its previously approved public version remains while correction is pending. Returned requests can be corrected and resent. Submitted or approved linked dossiers cannot be silently overwritten from the association site.

Refresh retrieves up to 500 recent receipts; there is no automatic background sync. Use the same open request form to retry a failed send. Reloading the page starts a new request form, so check receipts before sending the same request again.

MNCS can pause or rotate a connection. A rotated token invalidates the old token immediately; update the Darts Functions environment and redeploy. Pausing stops further exchanges but does not erase already published records. To withdraw public leader names, share a corrected summary with names disabled before pausing, or ask MNCS to handle the published record.

Credentials identify the association connector. This pilot authenticates a Darts site administrator but does not yet record a verified individual Darts user identity for each message. Existing MNCS decisions retain their council audit trail.

## Current status

Handler, SQL and DOM workflows were tested locally. Deployment and an authenticated live end-to-end exchange remain pending access to the complete Darts source and its deployment. Preserve all existing Darts functions and settings during the merge.
