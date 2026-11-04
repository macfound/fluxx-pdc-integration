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
    
    fluxx_field_desc = mapping.fluxx_field
    
    # Parse the description to extract the actual field name
    value = nil
    
    if fluxx_field_desc =~ /^(\w+)\s*\((core|dynamic)\):\s*(.+?)(?:\s*\[.+?\])?$/
      model_type = $1
      field_type = $2
      field_label = $3.strip
      
      # Convert label to field name
      field_name = field_label.downcase.gsub(/[\s\-]+/, '_')
      
      case model_type
      when "Organization"
        if model.respond_to?(:program_organization) && model.program_organization
          if model.program_organization.respond_to?(field_name)
            value = model.program_organization.send(field_name)
          end
        end
        
      when "GrantRequest"
        if model.respond_to?(field_name)
          value = model.send(field_name)
        end
      end
    end

    # If value is an object and we have a subfield defined, extract it
    if value.present? && 
      value.respond_to?(:attributes) && 
      mapping.fluxx_related_field_field_name.present?
      
      sub_field = mapping.fluxx_related_field_field_name
      if value.respond_to?(sub_field)
        value = value.send(sub_field)
      end
    end
    
    # The text PDC Send Proposal to PDC sends for this field (value.to_s).
    # Liquid can only render plain values, so the preview and the copy Stamp
    # Consent keeps hold this text, never the object itself. A value that is
    # still a whole record means the mapping names no field of it to send.
    value_text = value.to_s.strip
    record = !value.nil? && value.respond_to?(:attributes)

    # Store in hash using raw field name for API compatibility
    pdc_data[raw_pdc_field] = value_text

    # Store clean info for display (use string keys for Liquid compatibility)
    field_info << {
      "field_name" => clean_pdc_field,
      "value" => record ? "(a #{value.class.name.demodulize} record: choose which of its fields to send in this field's mapping)" : value_text,
      "source" => model_type || "Unknown",
      "has_value" => value_text != ""
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