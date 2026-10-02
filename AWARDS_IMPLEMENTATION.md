# Malawi Sport Awards module — v0.5

Source: Malawi Sport Awards Handbook, November 2024, sections 5–8 and 11–15.
The app contains 14 categories and summaries of their criteria. Normalised labels
correct the handbook's typographical error in the male disability category.

## Implemented now
- Awards navigation and category descriptions.
- Association nomination drafts with category, year, candidate, justification and
  private supporting PDF dossier. Include the handbook nomination form/contact
  details and applicable junior age evidence inside the PDF.
- Draft submission, corrections and MNCS eligibility-dossier review in Workspace.
- Database constraints for category/year, required evidence, declaration and
  duplicate active nominations within each submitting association.
- Tested, isolated 70/30 calculation helper, disabled without explicit approved
  normalization and certified vote tally inputs. It is not an official live ranking.

Run v0.5-migration.sql after the v0.4 migration, then deploy the code. Existing
records remain in place. An Approved award submission means eligibility-dossier
review only; it never denotes an award winner.

## Handbook selection stages
The qualifying achievement year is 1 January–31 December. The document sets
2024/25 nomination, adjudication and voting dates; these must not be reused for
new cycles. Nominations come from affiliated national associations and sports
journalists through SWAM. Screening uses seven appointed people; adjudication
uses five members, with a separate five-expert journalism committee. Adjudication
selects three finalists per category. Final scores combine 70% adjudication and
30% public voting. Independent auditors verify results, kept confidential until
announcement. Appeals are due within 24 hours of finalist/winner announcement;
the committee rules within 48 hours.

## Proposed numerical conventions needing MNCS approval
Judges score category criteria using an MNCS-approved rubric. Normalize each
judge's criterion-weighted score to 0–100, then aggregate panel scores under the
approved rule. Equal averaging is a proposal, not prescribed by the handbook.
The handbook gives no numerical criterion weights.

A proposed public score is 100 × valid votes for nominee / total valid votes for
that category's three finalists. Final score = 0.70 × adjudication score + 0.30 ×
public score. The helper uses this convention only when normalizationApproved
and tallyCertified are true. It rejects zero votes, invalid scores, invalid vote
counts and anything other than three distinct finalists. Exact ties remain ties;
no unapproved tie-breaker or redistribution of weights is applied.

## Decisions required before official adjudication or voting
- Junior age is strictly under 20 as clarified by the project owner. MNCS must
  still specify the reference date in each awards cycle.
- MNCS-approved per-criterion rubrics/weights, panel aggregation and tie-breakers.
- Dates, nomination route acceptance (the handbook specifies email/physical
  submissions), public vote normalization, voter verification and fraud controls.
- Sports Personality depends on winners of individual athlete categories; define
  when those winners are certified and how this fits public-voting dates.
- Confirm procedures for conduct/anti-doping checks. The app must not infer
  disqualification from unverified accusations or missing information.

## Next implementation stage
Assigned screener/judge/auditor roles, confidential individual scoring, approved
cycle configuration, locked finalist lists, certified public-vote ingestion or
verified voting service, aggregation snapshots, auditor sign-off, appeals and
controlled winner publication remain unimplemented. SWAM nomination routing is
also not yet implemented. Private rankings must not be published before release.
No medals-only rankings, invented category weights or automatic winners are used.

## v0.6 policy clarification
Junior eligibility is strictly under 20; a database trigger blocks submission or
approval without a cycle reference date or for candidates already 20. Existing
drafts can be completed with private birth-date evidence.

A judges-only scoring helper is provided as an openly stated proposed amendment.
It does not use fan votes and refuses calculation unless amendment approval and
public disclosure are explicitly supplied. The original handbook 70/30 helper is
retained, not secretly overridden. Actual votes, judges' input screens, confidential
server-side ranking and audits remain the next implementation stage.

Admins can configure cycle dates/policy in Awards. These settings do not turn on
official rankings. The consolidated installer is INSTALL_ALL.sql.
