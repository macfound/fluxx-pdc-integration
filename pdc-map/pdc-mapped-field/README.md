# PDC Mapped Field (`MacModelTypeDynPdcMappedField1`)

Child records of the PDC Integration Map (`MacModelTypeDynPdcApplicationForm1`).
Each record maps one PDC base field (`pdc_field`, a PDC short code) to one Fluxx
field (`fluxx_field`, a packed descriptor like `Organization (core): Name [string]`),
plus `pdc_field_position` and `pdc_application_field_instructions`.

It is created, sorted, updated, and deleted by methods on the Integration Map
model (see `../pdc-integration-map/`, e.g. `Update Field Mapping from Selected
Application.rb`, `Set Sort Order Of Mapped Fields.rb`, `Delete Field Mappings
on this Form.rb`). Its own methods hold the one rule for what a mapping sends:

- `Value For Grant` — the value sent for one grant (passed in as `@pdc_grant`):
  the Fluxx field, or its Fluxx Related Field when that's a record; a record
  still left sends its Fluxx id, an empty value `nil`. Used by
  `PDC Send Proposal to PDC` and the consent data preview.
- `Mapping Warning` — from the field definitions alone, a warning when the
  mapping will send a record's id or always nothing. Shown under each mapping
  in the Integration Map's Show Mapped Fields list (via `Mapped_Field_Warnings`).
