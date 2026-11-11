# PDC Populate Options
#
# Keeps the deploy model's instance-specific dropdowns in sync with this
# Fluxx instance (value = record id, description = name):
#   pdc_event_role       <- Role: who may click the Integration Map's buttons
#   pdc_grantee_profile  <- UserProfile: grantees, who view/update their own
#                           PDC Consent records (TRN: Grantee)
#   pdc_staff_profile    <- UserProfile: staff who may edit PDC fields that the
#                           Consent stencil restricts (TRN: Employee with
#                           Permissions Plus)
#   installer_role       <- Role: who may click the deploy model's own buttons
#   grant_request_themes <- GrantRequest themes whose forms get
#                           the PDC elements (interactive / read-only set)
#   pdc_environment      <- Production / Sandbox (fixed, from PDC Installer
#                           Lib): which PDC Install points Get PDC Base URL at
# and on the PDC Integration Map (once Install has created it):
#   grant_request_themes <- GrantRequest themes: grants of the themes a map
#                           lists use that map
# Profile names differ per org, so the admin chooses; profiles whose
# categories include "grantee" are labelled to help.
# Options for deleted records are retired, not removed. Safe to re-run. Only
# writes ModelAttributeValue rows, on the attributes above.

require 'json'

sync = lambda do |attr_name, records, model_type = model.class.name|
  attr = ModelAttribute.where(model_type: model_type, name: attr_name, deleted_at: nil).first
  next "#{attr_name}: attribute not found" if attr.nil?
  existing = {}
  ModelAttributeValue.where(model_attribute_id: attr.id, deleted_at: nil).each { |v| existing[v.value.to_s] = v }
  added = 0
  retired = 0
  records.each_with_index do |(id, label), i|
    v = existing.delete(id.to_s)
    if v.nil?
      ModelAttributeValue.create!(model_attribute_id: attr.id, value: id.to_s, description: label,
                                  display_order: i + 1, retired: false)
      added += 1
    elsif v.description != label || v.retired
      v.description = label
      v.retired = false
      v.save!
    end
  end
  existing.each_value do |v|
    next if v.retired
    v.retired = true
    v.save!
    retired += 1
  end
  "#{attr_name}: #{added} added, #{retired} retired"
end

roles = Role.where(deleted_at: nil).order(:name).map { |r| [r.id, r.name] }

# categories is a string holding a JSON array, e.g. "[\"\",\"grantee\"]"
live_profiles = UserProfile.column_names.include?('deleted_at') ? UserProfile.where(deleted_at: nil) : UserProfile.all
profiles = live_profiles.order(:name).map do |p|
  cats = begin
    Array(JSON.parse(p.categories.to_s))
  rescue JSON::ParserError
    []
  end
  [p.id, cats.include?('grantee') ? "#{p.name} (grantee)" : p.name]
end

themes = ModelTheme.where(model_type: 'GrantRequest', deleted_at: nil).order(:name).map { |t| [t.id, t.name] }

environments = model.dyn_invoke_for(:"PDC Installer Lib")[:pdc_environments].map { |value, env| [value, env['label']] }

[sync.call('installer_role', roles), sync.call('pdc_event_role', roles), sync.call('pdc_grantee_profile', profiles),
 sync.call('pdc_staff_profile', profiles), sync.call('grant_request_themes', themes),
 sync.call('pdc_environment', environments),
 "Integration Map #{sync.call('grant_request_themes', themes, 'MacModelTypeDynPdcApplicationForm1')}"].join('; ')
