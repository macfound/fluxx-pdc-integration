# PDC deploy model

The PDC integration is installed, updated, checked and removed from one dynamic model
inside Fluxx: the **deploy model**. Admins work entirely from its form: buttons run the
actions, and each action's results show on the form. The code reads what "correct" means
from this public repo, so nothing has to be copied by hand once the deploy model exists.

The deploy model stays in place after install. To remove PDC completely, click
**Uninstall**, review what it lists, then delete the deploy model.

## What's here

| Path | What it is |
|---|---|
| `pdc-scope.json` | Hand-maintained. *What* PDC consists of: owned models, GrantRequest pieces, secrets, exclusions, stencil-element fingerprints. |
| `pdc-manifest.json` | Generated, never hand-edited. Every PDC component with its natural key, settings, repo path and sha256. Validation compares against this. |
| `pdc-install-bundle.json` | Generated with the manifest. The same components with their bodies inlined, so Install and Uninstall need one fetch. |
| `installer/` | The deploy model's methods, its theme's Before New / After Create code, and its form (`stencil/`). Only `theme/Before New.rb` is pasted by hand; the rest is installed from `deploy-model.json` by the bootstrap. |
| `tools/pdc_manifest.rb` | Local Ruby (no gems) that builds and checks the manifest and the install bundle. |
| `tools/build_one_off_*.rb` | Build paste-in versions of the installer's actions, for testing in Fluxx before a push (see below). |

## One-time setup (needs an admin who can save custom Ruby)

1. **Create the deploy model** and name it **PDC Install Config**. (Nothing depends on the
   name, but using this one keeps every instance and these instructions in step.) Fluxx
   creates its theme, workflow and blank form automatically.
2. **Paste `installer/theme/Before New.rb`** into that theme's Before New block as is.
3. **Click New.** As the form opens, Before New downloads `PDC Bootstrap Deploy Model`
   and runs it. That builds the deploy model from `installer/deploy-model.json`: its
   fields and dropdowns, the Snapshot document type, installer methods, states, form,
   and the theme's After Create block.
   - The bootstrap uses `model.class`, so the model's name doesn't matter.
   - Re-running is safe at every level: each piece is looked up first and only
     created if it doesn't exist.
4. **Pick the Installer Role** (required: who may use the deploy model's buttons) and
   save. After Create runs the bootstrap again, which creates the buttons with that
   role. What it did shows on the form as **Installer update**.
   - Only one deploy record may exist. A second one deletes itself (Fluxx shows an
     error page), and deleting the only one undoes itself, since it holds the results
     and snapshots. To remove PDC, use Uninstall and then delete the deploy model.
5. Later, **Update Installer** re-runs the bootstrap against `repo_ref`, replacing the
   deploy model's own methods and form with the repo copy. Changing the Installer Role
   and clicking Update Installer moves the buttons to the new role.

## Using it

1. Open the deploy record that setup created. `repo_url`/`repo_ref` should be filled in
   (if they're blank, enter them; the installer also remembers them in a `PDC Repo
   Settings` method) and the dropdowns loaded; Refresh Lists reloads the dropdowns later.
2. Make the instance-specific choices. Names differ per org, so nothing is guessed, and
   each can hold several:
   - **Installer Role** (required): roles that may use the deploy model's buttons
   - **PDC Event Role**: roles that may click the PDC Integration Map's buttons; Install
     keeps those buttons' roles exactly in line with this list (TRN: Admin)
   - **PDC Grantee Profile**: grantee profiles that view and update their own PDC Consent
     records. Each gets the Consent permissions, the first dashboard page of each gets
     the OAuth callback, and the PDC group, its elements and the `pdc_account_exists`
     field on grant forms are shown to exactly these profiles (TRN: Grantee)
   - **PDC Staff Profile**: staff profiles allowed to see and edit the parts of the
     Consent form that are restricted (TRN: Employee with Permissions Plus)
   - **Grant Request Themes**: which grant themes show grantees the PDC component; each
     chosen theme's forms get both the edit and the read-only component (the edit one
     shows only in the edit view, the read-only one only in the detail view)
   - **PDC Environment**: Production or Sandbox, the PDC this instance talks to. Install
     writes the matching URL into the `Get PDC Base URL` method; to switch, change it and
     click Install again (with the other environment's credentials). While none is chosen,
     Install leaves that method alone and Validate reports it NOT_CONFIGURED
   - **PDC Client ID** / **PDC Client Secret**: the credentials the PDC issued you. Type
     them in and save: they're written into the `Get PDC Client ID` / `Get PDC Client
     Secret` methods on the PDC Integration Map (run Install first, so it exists) and the
     fields are cleared, so the values never stay on the deploy record, in its results
     or in snapshots. The form's Credentials section says what was saved.
3. Click a button:

   | Button | What it does |
   |---|---|
   | **Validate** | Read-only. Compares this instance with the repo at `repo_ref`, so it previews what Install would change. |
   | **Install** | Installs and updates. Installs what's missing, restores what was soft-deleted (same id, so saved answers keep working), and overwrites anything PDC owns that differs from the repo. To move to another release, change `repo_ref` and click Install. Never removes anything: methods, states or buttons PDC didn't ship belong to whoever built them. |
   | **Uninstall** | Removes what PDC owns, soft-deleting it as Fluxx does: PDC's fields, methods, states and buttons, its elements on forms and its block in the `granted` hook, and then the three PDC models with their themes, workflows and forms. Fluxx removes a model's records and other settings with it. Grant forms aren't edited: each active one gets a "(PDC Removed)" copy without PDC, switched on, and the form with PDC is switched off. Lists anything it isn't sure about for review. Restore Previous brings the configuration back; it doesn't restore records. |
   | **Restore Previous** | Puts every PDC component back the way it was before the last Install, Uninstall or Restore. Clicking it twice undoes the restore. |
   | **Refresh Lists** | Reloads the role, profile and theme dropdowns. |
   | **Update Installer** | Updates the deploy model itself from the repo. |

   Validate statuses:

   | Status | Meaning |
   |---|---|
   | `MATCH` | Present, and its checksum and settings agree with the repo |
   | `DIFFERS` | Present, but `detail` lists the checksum or setting that differs |
   | `MISSING` | No record with that name/key |
   | `EXTRA` | A live PDC record the manifest doesn't list (e.g. a leftover test method) |
   | `SKIPPED_SECRET` | Secret method (PDC client ID / secret): it exists and holds a value; the value is never read or compared |
   | `NOT_CONFIGURED` | Secret method still holds the placeholder `"Not Configured"`: replace it with this instance's value, keeping the quotes |
   | `MARKER_NOT_FOUND` | GrantRequest `granted` hook has no `###PDC_CODE###` block (Install adds it) |
   | `MISSING_ROLE` / `ROLE_DIFFERS` | Integration Map button has no role, or not the chosen one |
   | `UNMARKED` | PDC stencil element recognized by fingerprint but lacking its `PDC:ELEMENT` marker (Install adds it). As `UNMARKED_DIFFERS` it's left alone, unless Fluxx turned part of it into "undefined" |
   | `UNMARKED_DIFFERS` | Same as `UNMARKED`, but the element's content also differs from the repo copy |
   | `CONFIG_DIFFERS` | A PDC stencil element has Allow JavaScript off, or strips HTML (its scripts won't run), is in the wrong view, or sits in the PDC group on the dashboard page |
   | `PROFILE_DIFFERS` | A profile restriction doesn't match the deploy record's choices: Consent permissions or the PDC elements, group and field on grant forms and the dashboard page (PDC Grantee Profiles), or the restricted parts of the PDC models' forms (PDC Staff Profiles). Install fixes it. |
   | `ROLE_DIFFERS` (installer buttons) | One of the deploy model's own buttons doesn't have exactly the Installer Roles; Update Installer fixes it |
   | `AMBIGUOUS` | An element's fingerprints match more than one PDC element; needs a person to look |
   | `DUPLICATE` | The same PDC element appears more than once in one stencil |

Validation is read-only. The report keeps counts for everything, and detail for anything
that isn't `MATCH`.

## What Install does

- **The three PDC models** are kept if they exist, brought back if they were
  soft-deleted (same ids, so existing records reattach), or created with their exact
  internal names. Then their themes, workflows and forms, and the Consent permissions
  (list, view and update their own) for the **PDC Grantee Profile**. Two things in the
  repo's model forms are TRN's and are translated: profile restrictions become the
  **PDC Staff Profile**, and dropdown option ids in show/hide conditions become this
  instance's ids for the same options.
- **The PDC models' forms:** each PDC model has one active form. If there's exactly one,
  Install brings it up to the repo in place. If there's none, Install creates a new one
  (it never brings back a deleted form, including the old forms Fluxx un-deletes when a
  model is brought back). If there are several, Install creates a new one named with
  today's date (YYYY-MM-DD) and switches the others off. Restore Previous removes forms
  Install created and switches the others back on.
- **Their fields, options, methods, theme code, states and buttons**, and the
  GrantRequest pieces (fields and `PDC` methods).
- **PDC elements** go in a PDC group at the bottom of the grant forms of each theme
  chosen in **Grant Request Themes**: the edit component, the read-only component, and
  the `pdc_account_exists` field they read. The OAuth callback goes at the bottom of the
  first GenericTemplate on each **PDC Grantee Profile**'s dashboard, on its own (no PDC group, so grantees see no
  container; Install takes it out of one if it's there). Move them where they belong afterwards; Install finds them by
  their markers wherever they are.
- **Edit vs. detail view.** The edit component shows only in the edit view and the
  read-only component only in the detail view, so a grantee never sees both. Install
  sets this on every copy, including ones already on a form, and Validate reports a
  copy in the wrong view as CONFIG_DIFFERS. Switched-off grant forms (the rollback
  copies Install keeps) are never changed or checked.
- **Every active form of a chosen theme** gets the PDC component. Fluxx allows several
  enabled forms per theme (for example one per user profile), so a theme with an
  internal and an external form gets it on both; remove it from any form grantees don't
  use. Disabled forms and filters are never touched.
- **Grant forms are never edited in place.** Whenever an active grant form needs a
  change (a missing PDC component, or a PDC element whose text or settings differ from
  the repo), Install copies it exactly (visibility, profile restrictions and every other
  setting kept), makes the change on the copy, switches the copy on and the original
  off. The original, unchanged, is the rollback inside Fluxx. " (PDC)" is added to the
  copy's name once, so names can repeat. A theme with several active forms gets a copy
  of each. Switched-off forms are left alone. Restore Previous removes the copies and
  switches the originals back on. Uninstall works the same way: each active grant form
  with PDC is copied as "<name> (PDC Removed)" without the PDC elements and switched on,
  and the form with PDC (with any changes you made to it) is switched off, so you can
  switch between them. A later Install copies a "(PDC Removed)" form back as "(PDC)".
  (The grantee dashboard page is updated in place.)
- **The `###PDC_CODE###` block** goes at the top of GrantRequest's `granted` hook, so it
  always runs.
- If a PDC model still can't be set up, Install touches only the PDC models that exist:
  GrantRequest's PDC hooks call into all three, so they wait.
- Install never removes anything it doesn't recognize. The `Get PDC Client ID` /
  `Get PDC Client Secret` methods are created with the placeholder `"Not Configured"`
  if they don't exist, and never changed by Install afterwards: set them through the
  PDC Client ID / Secret fields on the deploy record (or replace the placeholder in
  Fluxx, keeping the quotes).

## Results and snapshots on the form

Each action saves what it did to a text field on the deploy record, newest shown first:
`installer_results`, `validate_results`, `install_results`, `uninstall_results`,
`restore_results`. `PDC_Results` reads them and the Liquid block in
[installer/stencil/Results.liquid](installer/stencil/Results.liquid) renders when each
ran, a count per status, and the items under every status except MATCH/ok.

**Configuration snapshots.** Install, Uninstall and Restore Previous save a snapshot of
the whole PDC configuration before they change anything, and another after. That covers
the PDC models, their themes, workflows and forms, fields and static options, methods,
states, buttons (with from-states and roles), the Consent permissions, the `granted`
hook, every form holding PDC elements or fields, and the PDC copies of grant forms.
Secret methods are recorded only as existing or deleted, never their values.

Each snapshot is a text document of type **Snapshot** on the deploy record, named like
`PDC snapshot 2026-10-19 14:05:00 UTC before Install (main).json`. All of them are kept
(the GrantRequest forms make each one 1–3 MB). `previous_configuration` and
`current_configuration` hold just a pointer to the latest before and after documents, and
Restore Previous follows `previous_configuration`. If a snapshot doesn't read back
intact, the action stops with nothing changed. The snapshot documents belong to the
deploy record and go with the deploy model if it's deleted, so download the last
snapshot first if you may need it.

About Restore Previous:
- A run that changes nothing doesn't replace what Restore Previous goes back to, but any
  run that does change something does, so restore before running anything else.
- It leaves alone anything someone changed, created or re-linked after the last action,
  and lists it for review. Forms are compared whole: any edit to a form since then,
  PDC-related or not, means that form isn't restored.

### The deploy model's form

The bootstrap (first record, and **Update Installer**) overwrites the deploy model's
form stencil with [installer/stencil/layout.json](installer/stencil/layout.json): the
settings fields and the results block. It isn't backed up; the layout lives in the repo.
Nothing else edits this stencil. Change the form by editing `layout.json` in the repo,
not in Fluxx, or the next Update Installer replaces your edits.

The same stencil holds the **list view** card: the first element in `layout.json` is
marked `list_only` (Fluxx's `visible_list`, as on the PDC Integration Map), so it shows
only in the list. `PDC_List_Summary` gathers what someone looking after the integration
checks first, and [installer/stencil/List.liquid](installer/stencil/List.liquid) renders
it: an overall status (Healthy, Check again, Needs attention, Not installed yet), the
PDC Environment, the repo ref and installer commit, the last Validate (and whether
anything ran since), the last Install / Uninstall / Restore, whether each credential
has been entered (never its value), how many grant themes and active Integration Maps
use PDC, and what Restore Previous would go back to.

## Advanced configuration

- **Which code is installed.** `repo_url` and `repo_ref` at the top of Before New say
  where the installer reads from (defaults: the macfound repo, `main`). Whatever is at
  that ref becomes Ruby that runs in your Fluxx, so in production consider pinning
  `repo_ref` to a release tag or commit SHA, and moving it forward deliberately. After
  setup, the same two settings are fields on the deploy record.

## Testing before a push

The buttons fetch from the repo. To try a change in Fluxx before pushing, build a
paste-in script that embeds what it needs, paste it into a temporary method on the
deploy model, and run it on the deploy record:

```bash
ruby deploy/tools/build_one_off_action.rb install    # also: validate, uninstall, restore
```

`build_one_off_layout.rb` does the same for the bootstrap's fields, document type and
form steps. Each script runs the same code as its button and saves the record, so the
results show on the form. The generated scripts go to `DEV/`, which git ignores.

## Updating the manifest (maintainers)

The manifest is generated from a known-good instance, then the repo files become the
source of truth:

```bash
# 1. ruby deploy/tools/build_one_off_export.rb, paste DEV/one-off-export.rb into a temporary
#    method on the deploy model, run it, and save the PDCEXPORT1 line it returns, e.g. export.json
# 2. Write the bodies into the repo and regenerate the manifest:
ruby deploy/tools/pdc_manifest.rb unpack export.json
# 3. Review git diff, commit, push. Then Validate in Fluxx should be all MATCH.
```

After editing a body in the repo, run `ruby deploy/tools/pdc_manifest.rb rehash`, which
also rewrites `pdc-install-bundle.json`. `ruby deploy/tools/pdc_manifest.rb check` fails
on stale hashes, missing files, an out-of-date bundle, or a data-explorer file whose
marker/fingerprints don't identify it uniquely; run it before committing.

Repo files remain authoritative for data-explorer stencil elements (they carry the
markers), so `unpack` never overwrites `data-explorer/`. Secret method bodies are never
exported.

## Scope rules

- **Owned** (`owned_model_types`): compared whole: models, attributes, static dropdown
  options, methods, theme hooks, states, events (minus roles, which are chosen per
  instance), and the main form stencil.
- **Shared** (GrantRequest, GenericTemplate): only `PDC`-prefixed methods, the
  `pdc_account_exists` / `pdc_proposal_id` attributes, the `###PDC_CODE###` slice of the
  `granted` hook, marked/fingerprinted stencil elements, and the "(PDC)" / "(PDC Removed)"
  copies of grant forms.
- **Dropdowns filled at runtime** (`runtime_option_attributes`): the attribute must exist;
  its options aren't compared.
- `ModelAttributeChoice` holds per-record values and is never read or written.
