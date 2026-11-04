# Deployment

The deploy model installs and updates most of PDC from this repo: set it up as
described in [deploy/README.md](../deploy/README.md), then click **Install**. File
contents here are the source of truth for what ends up in Fluxx.

Install sets up everything PDC needs: the three PDC models (with their themes,
workflows, forms and Consent permissions), their fields, methods, states and buttons,
the GrantRequest pieces, the PDC component on the forms of the themes chosen on the
deploy model, the OAuth callback on the grantee dashboard page, and the `###PDC_CODE###`
block in the `granted` hook. What's left by hand:
- entering the real PDC client ID and secret
- moving the added PDC groups to where they belong on each form

The rest of this page is reference: where each repo file ends up in Fluxx, how the
grantee journey behaves, and what to check per environment.

## What goes where

| Repo path | Fluxx destination |
|---|---|
| `pdc-map/grant-request/*.rb` | Methods/hooks on `GrantRequest`. Files named `AfterEnter…` / `PDC After Save…` are lifecycle hooks; the rest are named methods (deployed method name = file name without `.rb`) |
| `pdc-map/pdc-integration-map/*.rb` | Methods/hooks on `MacModelTypeDynPdcApplicationForm1` (`Before New.rb` is the before-new hook) |
| `pdc-map/pdc-integration-map/Show Mapped Fields.html` | Liquid block on the Integration Map form |
| `pdc-map/pdc-consent/*.rb`, `Data Shared.liquid` | Methods / Liquid on `MacModelTypeDynPdcConsent` |
| `data-explorer/0…5 *.html` | Blocks on the grantee-facing form/stencil, in numeric order |
| `data-explorer/4r. pdc-stencil-readonly.html` | Read-only journey block — see "Read-only journey variant" below |
| `data-explorer/oauth-callback.html` | Page served at the OAuth redirect URI registered with PDC |

## Read-only journey variant

`data-explorer/4r. pdc-stencil-readonly.html` is a view-only twin of block 4. It
renders the same 4-step journey and keeps the live "Review and Manage Consent"
modal link, but drops every JS-driven element (account-gate dropdown,
login/logout controls, launch button, explorer panel, structure-ready signal).
Use it where the login/launch flow is unwanted.

- **Block set:** `1. portal-style.html` (CSS, reused as-is) + `4r. pdc-stencil-readonly.html`,
  plus `0. information.html` if an intro is wanted.
- **Do NOT deploy** blocks `2`, `3`, `5`, or `oauth-callback.html` with it — this
  variant runs **no custom JavaScript**. The consent link is native Fluxx
  (`to-modal` + `data-on-success="refreshCaller,close"`).
- The consent step still needs the `MacModelTypeDynPdcConsent` model deployed so
  the `dyn_related` Liquid resolves and the modal link works.

## Consent step states

Step 2 of the journey (both block `4` and block `4r`) resolves two independent
booleans server-side in Liquid. Both are documented at length in the comment above
the tags; the deploy-relevant behavior:

| Consent record | `consent_type` | Step 2 renders |
|---|---|---|
| exists | affirmative (non-blank, no "decline") | complete branch: green check, "Done", CTA |
| exists | contains "decline" | action branch: "Action needed", CTA |
| exists | blank (not yet answered) | action branch: "Action needed", CTA |
| **none** | — | action branch: explanatory text, **no CTA** |

The last row is **by design, not a bug**: grants created before 2026-07-01 have no
consent record, because `PDC After Save - Create Consent If Empty` only creates
them at or after that date. Previously the CTA rendered anyway and linked to
`/machine_models//edit` (empty id). If the button is reported missing on an older
grant, that is this rule working.

"Granted" is tested as *non-blank and not containing "decline"* rather than as an
exact match on the dropdown label, mirroring `PDC Send Proposal to PDC`. Rewording
the affirmative choice therefore does not break the journey; renaming the **decline**
choice to drop that word would. Keep "decline" in the negative option's label.

## Environment & secrets checklist (before any production deploy)

- [ ] Enter real client secrets **only in Fluxx** (`Get PDC Client
      Secret` methods). The repo copies must keep returning `"Not Configured"`.
- [x] `Get Auth Token from PDC.rb` reads the client ID and secret from
      `Get PDC Client ID` / `Get PDC Client Secret`; there's no inline value left.
- [x] `5. floating-panel.html`: proposals endpoint points at production
      (`api.philanthropydatacommons.org`), matching the OAuth environment in
      `3. oauth.html`. Both browser-side layers now target production so the
      prod-issued token is used against the prod API.
- [ ] `3. oauth.html`: confirm client ID (`pdc-fluxx-macfound`) and auth
      endpoints match the target environment; register `oauth-callback.html`'s
      URL as the redirect URI with PDC.
- [ ] Deploy record: choose the **PDC Environment** (Production or Sandbox) and
      click Install, which writes the matching URL into `Get PDC Base URL`.
- [ ] `CurrentConsentLanguage.rb`: the Q&A link is a placeholder
      (`https://yoursite.invalid/pdc-consent-qa`) and the contact address is
      MacArthur's; point both at your own consent Q&A and contact before going live.

## The deploy model

Installing, updating, validating and removing PDC are handled by the deploy model; see
[deploy/README.md](../deploy/README.md). Its manifest
([deploy/pdc-manifest.json](../deploy/pdc-manifest.json)) maps every repo path
to its Fluxx model, record and type. Secret method bodies are never exported or
installed from the repo; set them in Fluxx directly.
