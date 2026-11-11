# PDC ↔ Fluxx Integration

Integration between the MacArthur Foundation's Fluxx grants-management system and
the [Philanthropy Data Commons](https://philanthropydatacommons.org/) (PDC).

Fluxx is vendor-managed: nothing in this repo runs as a normal Ruby application.
Ruby files become *dynamic model methods/hooks* on a specific Fluxx model, and
HTML/Liquid files become card blocks or stencil components. They're installed,
updated, validated and removed from a **deploy model** inside Fluxx that reads this
repo; see [deploy/README.md](deploy/README.md).

## The two components

### 1. `pdc-map/` — staff-side push (Fluxx → PDC)

Sends grant data *to* the PDC once a grantee has consented. Organized one folder
per Fluxx model, because that is the deployment unit:

| Folder | Fluxx model | Role |
|---|---|---|
| `grant-request/` | `GrantRequest` (core) | Orchestration: consent creation on save, proposal submission on entering the Granted state |
| `pdc-integration-map/` | `MacModelTypeDynPdcApplicationForm1` | The admin-configured map record: PDC auth/environment, dropdown sync from the PDC API, field-mapping management, creating applications/proposals in PDC |
| `pdc-mapped-field/` | `MacModelTypeDynPdcMappedField1` | Child field-mapping records (no methods of its own yet — see its README) |
| `pdc-consent/` | `MacModelTypeDynPdcConsent` | Consent language/versioning, consent stamping (audit trail), shared-data preview |

Typical flow: staff configure an Integration Map record (dropdowns populated
from PDC via the `Set … Dropdown Values` methods), map PDC fields to Fluxx
fields, and when a `GrantRequest` enters **Granted**, the
`AfterEnter - Granted` hook validates consent and runs
`PDC Send Proposal to PDC`, which walks the mapped fields and posts a proposal
version to the PDC API.

### 2. `data-explorer/` — grantee-facing pull (PDC → Fluxx form)

A client-side component embedded in the grantee portal form. After OAuth (PKCE)
login to the PDC, it fetches the grantee's prior proposals into a floating
panel and lets them auto-populate or drag-and-drop values onto the open Fluxx
form. **The numeric prefixes are a strict load order**:

0. `0. information.html` — grantee-facing PDC explainer + consent status
1. `1. portal-style.html` — all CSS
2. `2. fluxxCardAPI.html` — form-field scanning/set-value utilities (`window.fluxxAPI`)
3. `3. oauth.html` — OAuth 2.0 PKCE client (`window.OAuthClient`)
4. `4. pdc-stencil-container.html` — stencil markup + Liquid (embeds the field mapping)
5. `5. floating-panel.html` — main behavior; depends on 2, 3, and 4

`oauth-callback.html` is the popup redirect target and must be reachable at the
redirect URI registered with the PDC OAuth provider.

### The bridge between them

The Data Explorer's field matching is driven by a mapping generated on the
staff side: block 4's Liquid calls `PDC_Get_PDC_Field_Mapping` (a `GrantRequest`
method in `pdc-map/grant-request/`), which invokes
`Get Field Mapping JSON for PDC Data Explorer` on the Integration Map record
and returns Base64-encoded JSON that block 5 decodes. This is the only coupling
between the two components.

## Rules of the road

- **File names are identifiers.** Each `.rb` file name is the exact Fluxx
  method/hook name; methods call each other by name via
  `model.dyn_invoke_for(:"Method Name")`. Renaming a file here without renaming
  the method in Fluxx (and every call site) breaks the integration.
- **Credentials never live in this repo.** `Get PDC Client ID.rb` and
  `Get PDC Client Secret.rb` are placeholders returning `"Not Configured"`. Each
  instance enters its own values in Fluxx. The installer never writes, backs up or
  removes either method; snapshots record only whether they exist.
- `docs/architecture.md` has the method dependency map; `docs/deployment.md`
  has deployment order and known environment-specific values.

## Repo layout

```
pdc-map/         # staff-side Fluxx → PDC (Ruby, one folder per Fluxx model)
data-explorer/   # grantee-facing PDC → Fluxx component (HTML/JS/Liquid, load order 0–5)
deploy/          # the in-Fluxx installer (deploy model), manifest and tools
docs/            # architecture + deployment notes
```
