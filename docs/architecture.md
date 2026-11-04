# Architecture & method dependency map

All Ruby files are Fluxx dynamic model methods or lifecycle hooks. A method's
file name is its Fluxx method name; cross-method calls use
`model.dyn_invoke_for(:"Method Name")`, so these names are load-bearing.

## Fluxx models involved

- `GrantRequest` — core Fluxx model
- `MacModelTypeDynPdcApplicationForm1` — "PDC Integration Map" (admin-configured)
- `MacModelTypeDynPdcMappedField1` — "PDC Mapped Field" (children of the map,
  reached via `reverse_pdc_mapping_field_MacModelTypeDynPdcMappedField1`)
- `MacModelTypeDynPdcConsent` — "PDC Consent" (one per grant, linked via
  `grant_or_request_id`)

> Note: capitalization of the dynamic model names is inconsistent in places
> (`Pdc` vs `PDC`, e.g. `MacModelTypeDynPDCMappedField1` inside
> `Set Fluxx Field Model Attribute Choices.rb` and
> `MacModelTypeDynPDCApplicationForm1` in `PDC_Get_PDC_Field_Mapping.rb`).
> These strings must match whatever the live Fluxx instance uses.

## Submission pipeline call graph

```
GrantRequest hooks
  AfterEnter - Granted ──► PDC Safe Consent Form Lookup
                       └─► Send Proposal to PDC        (deployed name of
                                                        "PDC Send Proposal to PDC.rb")
  PDC After Save - Create Consent If Empty
                       ──► PDC Safe Consent Form Lookup
                       └─► PDC Create Consent Form ──► PDC Get Last Consent Response
                                                   ├─► CurrentConsentLanguage   [consent model]
                                                   └─► CurrentConsentVersion    [consent model]

GrantRequest methods
  PDC Send Proposal to PDC ──► PDC Safe Consent Form Lookup
                           ├─► PDC Get Integration Mapping
                           ├─► PDC Get Proposal by ID from PDC
                           ├─► Get PDC Base URL            [on the map record]
                           ├─► Get Auth Token from PDC     [on the map record]
                           └─► reads MacModelTypeDynPdcMappedField1 children
  PDC_Get_Data_Preview_For_Proposal ──► PDC Get Integration Mapping
  PDC_Get_PDC_Field_Mapping ──► Get Field Mapping JSON for PDC Data Explorer
                                 [on the first map record — see TODO in file]

PDC Consent model
  Check If Consent Granted (on consent_type change) ──► Stamp Consent
  Stamp Consent ──► PDC_Get_Data_Preview_For_Proposal   [on the grant]
  Data Shared.liquid ──► PDC_Get_Data_Preview_For_Proposal

PDC Integration Map model — foundations used by nearly everything:
  Get PDC Base URL          (written by Install from the deploy record's PDC Environment)
  Get Auth Token from PDC   (client-credentials token, cached on the record)
    ├─► Get PDC Client Secret
    └─► (client IDs currently inline / in Get PDC Client ID methods)
  Setup/sync methods:
    Set Opportunity Dropdown Values ──► Get Opportunities from PDC
    Set Application Dropdown Values ──► Get Applications from PDC
    Set PDC Field Model Attribute Choices        (GET /baseFields)
    Set Fluxx Field Model Attribute Choices      (introspects GrantRequest/Organization)
    Update Field Mapping from Selected Application ──► Get Application Form by Id from PDC
    Set Sort Order Of Mapped Fields ──► SortMappedFieldsbyFieldPosition
  Actions:
    Create Application In PDC   (POST /applicationForms)
    Create Proposals in PDC     (POST /proposals, via Relationship to GrantRequest)
    Get Funder from PDC         (GET /funders/{short_code})
    Get Grant Requests Related  (Base64 JSON of linked grants)
  UI:
    Show Mapped Fields.html ──► SortMappedFieldsbyFieldPosition
```

## Data Explorer load order & dependencies

```
1. portal-style.html      CSS for blocks 4 & 5
2. fluxxCardAPI.html      exposes window.fluxxAPI / fluxxFieldUtils / DropTargetManager
3. oauth.html             exposes window.OAuthClient (PKCE popup flow)
4. pdc-stencil-container  markup + Liquid; embeds Base64 mapping from
                          model.PDC_Get_PDC_Field_Mapping; sets window._pdcStructureReady
5. floating-panel.html    behavior; requires 2, 3, 4; initializes via img-onload
oauth-callback.html       popup redirect target; postMessages code/state to opener
```

Elements are resolved by `data-original-id` (not `id`) because Fluxx injects a
fresh copy of the stencil per card; block 5 scopes lookups to the active card.

## Known issues carried over from the offline copy

These were deliberately **not** fixed during the repo migration (contents were
kept byte-identical to what is deployed/tested):

- `grant-request/PDC_Get_PDC_Field_Mapping.rb` — uses `.first` map record;
  selection logic TODO is documented in the file header.
- `pdc-consent/CurrentConsentLanguage.rb` — the Q&A link is a placeholder
  (`yoursite.invalid`), and the contact address and "the Foundation" wording are
  MacArthur's.
- `Get PDC Client Secret.rb` returns `"Not Configured"` in the repo; each instance
  enters its own value in Fluxx.

## Fluxx configuration reference

How the pieces of the integration are stored in Fluxx. Confirmed against TRN
(2026-09 to 2026-10) while building the deploy tooling; the deploy model
([deploy/README.md](../deploy/README.md)) relies on all of it.

| Piece | Where it lives | Matched by |
|---|---|---|
| Dynamic model | `MachineModelType` | `model_type` |
| Field | `ModelAttribute` | `model_type` + `name` |
| Dropdown option | `ModelAttributeValue` (`value`, `description`, `display_order`, `retired`) | attribute + `value` |
| A record's selected value | `ModelAttributeChoice` (`model_id` = the record) | record data; never installed |
| Method / save hook | `ModelMethod.unsafe_dyn_method`; `method_type` is `method`, `before_save` or `after_save` | `model_type` + `name` |
| Before New / After Create | `ModelTheme.unsafe_before_new_block` / `unsafe_after_create_block` | `model_type` + theme `name` |
| Workflow state | `MachineState` (one row per model type, shared by every theme); hooks in `unsafe_before_validation_enter` / `unsafe_after_enter` | `model_type` + `name` |
| Workflow | `MachineWorkflow`, one per `ModelTheme` | theme |
| Button | `MachineEvent` (`to_state_id`, `unsafe_guard`, `filter`) + `machine_event_from_states` (the states it shows on; Fluxx sets `button_order` itself, so it is not compared) + `machine_event_roles` | workflow + `button_name` |
| Layout | `Stencil.json` (element tree; groups nest children under `elements`) | see below |
| Profile permission | `UserProfileRule` (`permission_name`, `allowed`) | `model_type` + `permission_name` |

Ids differ on every instance, so nothing should be matched by id.

**GrantRequest hooks.** The PDC send-on-grant logic sits in the shared
`granted` state's `unsafe_after_enter`, between `###PDC_CODE###` and
`###END_PDC_CODE###`. Because states are shared, every theme whose workflow
reaches `granted` runs it (4 of 5 themes on TRN). `ModelTheme` hooks on
GrantRequest hold only unrelated form defaults.

**Button pattern.** A button is an event with `is_validation_suppressed` that
moves the record into a transition state; that state's
`unsafe_before_validation_enter` runs `model.state = model.state_was` and then
`model.dyn_invoke_for(:"Method Name")`. Events need a role or they won't save.

**Stencils.**
- Element text is stored as typed (entities like `&#10003;` survive), but
  Fluxx's stencil editor rewrites what it touches. It flattens multi-line
  tags, stores Liquid `>` as `&gt;`, and can inject
  `<span class='mceNonEditable liquid-output'>` into HTML attributes. That
  last one broke the stencil-container block on GrantRequest stencil 26253
  (theme 13948).
- On GrantRequest form stencils the Data Explorer blocks sit inside one group,
  "Contribute to the Philanthropy Data Commons (PDC)". The group can't carry a
  marker, so it's found by its contents.
- A stencil's `form_type` is a serialized array; each model also has a
  `Filter` stencil. Imports can leave several identical `default` stencils
  (the Integration Map has three on TRN).
- `user_profile` settings inside a stencil hold UserProfile ids, which differ
  per instance.

**OAuth callback page.** It's an element in a GenericTemplate stencil. A
dashboard card URL `/generic_templates/{id}` is a `Stencil` id with
`model_type` `GenericTemplate`. The page is reached from a grantee profile's
dashboard: UserProfile (`categories`, a JSON string, includes `"grantee"`) →
`dashboard_template_ids[0]` → `DashboardTemplate.data` → `cards[].detail.url`.
TRN has two grantee-category profiles (Grantee 77, Borrower 1779), so the
profile has to be chosen, not guessed.

**Environment.** Whether an instance talks to the production or the sandbox PDC
is the deploy record's **PDC Environment** field. Install writes the matching URL
into `Get PDC Base URL` (the repo copy holds the sandbox URL), and Validate
compares the method against the chosen environment; with none chosen, Install
leaves the method alone and Validate reports it NOT_CONFIGURED.

**Per-instance placeholders.** `CurrentConsentLanguage`'s Q&A link is a
placeholder to replace per instance.

**Secrets.** `Get PDC Client ID` and `Get PDC Client Secret` hold real
credentials in Fluxx and placeholders in the repo. They are never exported or
compared.

**REST API limits.** Why install runs as Ruby inside Fluxx instead of through
the API:
- Saving any custom-Ruby field over REST fails for non-super-admins ("unable
  to make updates to custom Ruby fields").
- `DELETE` only soft-deletes, and soft-deleted records can't be found again.
- The `filter` parameter is ignored, so lists must be filtered client-side;
  `per_page` maxes out at 500.

Ruby running inside Fluxx has none of these limits. Its `destroy` hard-deletes
config records, so the installer never uses it: it soft-deletes (sets `deleted_at`,
as the GUI does), brings soft-deleted records back with their ids, and saves a
snapshot document of the whole PDC configuration before changing anything.
