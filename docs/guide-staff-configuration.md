# Configuring the PDC Integration

*A guide for MacArthur Foundation staff who set up and maintain the PDC ↔ Fluxx
integration.*

This guide explains, in practical terms, how to configure and update the
integration that connects Fluxx to the Philanthropy Data Commons (PDC). It
assumes you are comfortable working in the Fluxx UI and you already have a funder 
organization set up with the PDC. It does **not** cover the initial code deployment — 
for that, see [`deployment.md`](deployment.md). For how the pieces fit together under 
the hood, see [`architecture.md`](architecture.md).

---

## The big picture

The integration has two halves:

- **The funder-side push (Fluxx → PDC):** once a grantee consents and a grant is
  awarded, mapped fields from the grant are sent to the PDC as a proposal.
- **The grantee-facing pull (PDC → Fluxx):** the Data Explorer on the
  application form lets grantees reuse data they've already put in the PDC.

Almost everything you configure lives on one record type: the **PDC Integration
Map** (called `MacModelTypeDynPdcApplicationForm1` internally). One Integration
Map record ties together:

- **Which PDC environment and account** to talk to (auth + base URL).
- **Which PDC opportunity and application form** this map corresponds to.
- **A set of field mappings** — each one connecting a PDC field to a Fluxx
  field. These are stored as child **PDC Mapped Field** records.

The consent experience and the Data Explorer both read from this configuration,
so getting the Integration Map right is the core of the job.

---

## Before you start: one-time foundations

These are set up during deployment but are worth confirming before you configure
a map, because everything else depends on them:

- **Credentials and environment.** The integration authenticates to the PDC
  using a client ID and secret stored **in Fluxx only** (never in the code
  repo). Confirm the correct environment (sandbox vs. production) is in use and
  that the auth token can be obtained. If auth fails, no dropdowns will populate
  and nothing can be sent.
- **The consent language.** The text a grantee agrees to is maintained centrally.
  If the consent wording, the linked Q&A page, or the legal contact needs to
  change, that's a content change to the consent configuration — coordinate with
  Legal before editing it.

> If dropdowns come up empty or you see "Unauthorized" errors while configuring,
> the problem is almost always here (environment or credentials), not in your
> mapping. Stop and resolve authentication first.

---

## Setting up a new Integration Map

### Step 1 — Create the Integration Map record

Create a new PDC Integration Map record. On creation, the form pre-fills the
**funder short code** and **opportunity** from the most recently created map, so
if you're setting up a similar map you'll usually only need to adjust them. If 
this is the first Integration Map, use the funder short code provided by the PDC when
you set up your funder organization with them.

### Step 2 — Populate the dropdowns from the PDC

Several fields are dropdowns whose choices come *live from the PDC API*. You
populate them by running the corresponding setup action on the record. Run these
after the record exists and authentication is working:

| What it populates | What it does |
|---|---|
| **Opportunity dropdown** | Fetches the list of opportunities from the PDC so you can pick the right one |
| **Application dropdown** | Fetches the PDC application forms so you can pick which one this map represents |
| **PDC field choices** | Loads the master list of PDC base fields (the fields you can map *to*) |
| **Fluxx field choices** | Scans the Grant and Organization models so you can pick which Fluxx fields to map *from* |

Run each of these once. They create the underlying choice lists; you won't see
the right options in the dropdowns until they've been run.

> **Re-run these whenever the source changes.** If the PDC adds a new base field,
> or a new opportunity/application form appears in the PDC, re-run the relevant
> setup action to refresh the choices. If a new field is added to the Grant or
> Organization model in Fluxx and you want to map it, re-run the Fluxx field
> choices action.

### Step 3 — Select the opportunity and application form

With the dropdowns populated, choose:

- The **opportunity** this map corresponds to, and
- The **application form** from the PDC that you want to mirror.

### Step 4 — Build the field mappings

This is the heart of the configuration. Each mapping says: *"this PDC field
corresponds to this Fluxx field."* You have two ways to create them:

**Option A — Add or edit mappings by hand.**
On the Integration Map form there's a **"Show Mapped Fields"** view listing every
mapping with an **Add**, **Edit**, **View**, and **Delete** action. Use it to:

- **Add a Field Mapping** manually.
- **Edit** a mapping to set or change its Fluxx field, PDC field, position, or
  instructions.
- **Delete** mappings you don't want.

Each mapping has four parts:

| Field | Meaning |
|---|---|
| **PDC field** | The PDC base field being filled (chosen from the PDC field choices) |
| **Fluxx field** | The Grant or Organization field the value comes from (chosen from the Fluxx field choices) |
| **Position** | The order this field appears in |
| **Instructions** | Guidance text (auto-filled from the PDC form when generated in Option A) |

The Show Mapped Fields view flags each mapping with a **✓** when all four parts
are filled and a **⚠** when something is missing — use that to spot incomplete
mappings at a glance.

**Option B — Generate from the selected PDC application form (if one already exists at the PDC).**
Run the **"Update Field Mapping from Selected Application"** action. This reads
the fields defined on the PDC application form you selected and, for each one:

- **Creates** a mapping record for any PDC field that doesn't have one yet.
- **Skips** fields that already have a mapping (existing mappings are not
  overwritten).
- **Deletes** mappings whose PDC field is no longer on the application form.
- **Skips + reports** any PDC field that isn't in your loaded PDC field choices
  (usually a sign you need to re-run "PDC field choices" from Step 2).

This gives you a mapping record per PDC field, pre-filled with the PDC field, its
position, and the field's instructions from the PDC form. **It does not guess the
Fluxx side** — you still need to set which Fluxx field each one maps from
(Option A).

### Step 5 — Check completeness and ordering

- Every mapping should show a **✓** (all four parts filled). Fix any **⚠** rows.
- The list is shown in position order. If you need to change the order, there's a
  sort action that renumbers the mappings by their field position.

---

## Updating an existing configuration

Common maintenance tasks and how to handle them:

| Situation | What to do |
|---|---|
| PDC added or renamed a base field | Re-run **PDC field choices**, then re-run **Update Field Mapping from Selected Application** to pick it up |
| PDC application form changed (fields added/removed) | Re-run **Update Field Mapping from Selected Application**; it adds new mappings and removes ones no longer on the form |
| You want to map a Fluxx field that's new | Re-run **Fluxx field choices**, then edit the relevant mapping to select it |
| A single mapping is wrong | Edit it directly in the Show Mapped Fields view |
| Mappings are out of order | Run the sort-by-position action |
| Consent wording needs to change | Coordinate with Legal; update the consent configuration (not a mapping change) |
| Switching environments (sandbox ↔ production) | This is a deployment/credentials change: change PDC Environment and the credentials on the PDC deploy record, then click Install — see [`deployment.md`](deployment.md). Not something you toggle per map |

> **"Update Field Mapping" is safe to re-run.** It won't overwrite Fluxx-side
> mappings you've already set — it skips fields that already have a mapping. Its
> job is to keep the *set* of PDC fields in sync with the PDC application form.
> It *will* delete a mapping if that PDC field is no longer on the form, so if
> you've been keeping a mapping around intentionally, be aware of that.

---

## What the grantee sees (so you know what your config drives)

Your configuration directly shapes the grantee experience:

- **The consent step** shows grantees a preview of the exact fields that will be
  shared — that preview is built from your field mappings.
- **The Data Explorer** matches a grantee's prior PDC submissions to the current
  form using the same mapping. Good, complete mappings mean more fields auto-fill
  correctly for the grantee.

So an incomplete or incorrect mapping doesn't just affect what's sent to the PDC
— it also degrades the reuse experience for grantees.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Dropdowns are empty | Setup actions not run, or auth failing | Confirm auth/environment, then run the Step 2 setup actions |
| "Unauthorized" error | Bad or expired credentials / wrong environment | Resolve credentials in Fluxx (see deployment notes) |
| A PDC field won't map | It's not in the loaded PDC field choices | Re-run **PDC field choices** |
| Generating mappings skips a field | Same as above, or the field has no short code | Check the summary output; re-run field choices |
| Mapping shows **⚠** | One of the four parts (PDC field, Fluxx field, position, instructions) is blank | Edit the mapping and fill the missing part |
| Grantee reports data didn't auto-fill | Mapping incomplete or Fluxx field wrong | Review the mapping for that field |
| Data not appearing in PDC after a grant is awarded | Consent not granted, or awarding step hasn't run | Confirm the grantee consented and the grant reached the awarded state |

For anything below the surface (method names, environment detection, known
issues), consult [`architecture.md`](architecture.md) and
[`deployment.md`](deployment.md).
