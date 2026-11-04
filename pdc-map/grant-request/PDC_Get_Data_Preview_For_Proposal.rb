# Build PDC Proposal Data Preview from Grant Request
# Returns a structured hash with cleaned field names and values
# Can be displayed for consent or converted to JSON for API calls

require 'json'

application_form = model.dyn_invoke_for(:"PDC Get Integration Mapping")
unless application_form
  raise "No active PDC Integration Map has this grant's theme (#{model.model_theme&.name}): choose it in a map's Grant Request Themes."
end

# Get all field mappings for this application form
field_mappings = application_form.reverse_pdc_mapping_field_MacModelTypeDynPdcMappedField1

# Build the data structure
pdc_data = {}
field_info = [] # For preview display

field_mappings.each do |mapping|
  begin
    # Skip if missing required fields
    next unless mapping.respond_to?(:pdc_field) && mapping.pdc_field.present?
    next unless mapping.respond_to?(:fluxx_field) && mapping.fluxx_field.present?
    
    # Clean PDC field name - remove everything after " - "
    raw_pdc_field = mapping.pdc_field
    clean_pdc_field = raw_pdc_field.split(' - ').first.strip
    
    # The value PDC Send Proposal to PDC sends for this field (Value For Grant
    # on PDC Mapped Field): plain text or nil, which Liquid can always render,
    # also in the copy Stamp Consent keeps
    mapping.instance_variable_set(:@pdc_grant, model)
    value = mapping.dyn_invoke_for(:"Value For Grant")
    model_type = mapping.fluxx_field.to_s[/\A(\w+)/, 1]

    # Store in hash using raw field name for API compatibility
    pdc_data[raw_pdc_field] = value

    # Store clean info for display (use string keys for Liquid compatibility)
    field_info << {
      "field_name" => clean_pdc_field,
      "value" => value,
      "source" => model_type || "Unknown",
      "has_value" => !value.nil?
    }

  rescue => e
    # Skip fields that cause errors but don't fail the whole process
    next
  end
end

# Return structure that can be used for display or API (use string keys for Liquid)
{
  "display_fields" => field_info.sort_by { |f| [f["source"], f["field_name"]] },
  "api_data" => pdc_data,
  "summary" => {
    "total_fields" => field_info.length,
    "fields_with_values" => field_info.count { |f| f["has_value"] },
    "fields_without_values" => field_info.count { |f| !f["has_value"] }
  }
}