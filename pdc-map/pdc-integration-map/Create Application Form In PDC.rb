# Create Application Form in PDC
# Creates a new application form with field mappings
# Returns the created application form object
# Raises error if creation fails or required data is missing

require 'net/http'
require 'uri'
require 'json'

# Validate required fields
if !model.respond_to?(:opportunity) || model.opportunity.blank?
  raise "Opportunity is required to create an application form"
end

# Get opportunity ID (handle both ID and description storage)
opportunity_id = model.opportunity

# If stored as description, look up the actual ID
if opportunity_id.to_s !~ /^\d+$/
  opportunity_attribute = ModelAttribute.find_by(
    model_type: model.class.name,
    name: "opportunity"
  )

  if opportunity_attribute
    attr_value = ModelAttributeValue.find_by(
      model_attribute_id: opportunity_attribute.id,
      description: opportunity_id
    )

    if attr_value && attr_value.name.present?
      opportunity_id = attr_value.name
    else
      raise "Could not find opportunity ID for: #{opportunity_id}"
    end
  end
end

# Get field mappings
mappings = model.reverse_pdc_mapping_field_MacModelTypeDynPdcMappedField1.to_a

if mappings.empty?
  raise "No field mappings found. Add field mappings before creating application form."
end

# Get model attributes for lookups
pdc_field_attribute = ModelAttribute.find_by(
  model_type: "MacModelTypeDynPdcMappedField1",
  name: "pdc_field"
)

fluxx_field_attribute = ModelAttribute.find_by(
  model_type: "MacModelTypeDynPdcMappedField1",
  name: "fluxx_field"
)

if pdc_field_attribute.nil? || fluxx_field_attribute.nil?
  raise "Required field attributes not found for PDC mapping"
end

# Pre-load all attribute values for efficient lookup
pdc_field_values = ModelAttributeValue.where(
  model_attribute_id: pdc_field_attribute.id
).index_by(&:description)

fluxx_field_values = ModelAttributeValue.where(
  model_attribute_id: fluxx_field_attribute.id
).index_by(&:value)

# Build fields array for API
fields = []
errors = []

mappings.each_with_index do |mapping, index|
  begin
    # Get PDC field short code
    pdc_field_code = nil
    if mapping.respond_to?(:pdc_field) && mapping.pdc_field.present?
      # The pdc_field contains the description, need to get the value (short code)
      pdc_value = pdc_field_values[mapping.pdc_field]
      if pdc_value
        pdc_field_code = pdc_value.value
      else
        # Try direct lookup by value in case it's stored as short code
        direct_value = ModelAttributeValue.find_by(
          model_attribute_id: pdc_field_attribute.id,
          value: mapping.pdc_field
        )
        pdc_field_code = direct_value.value if direct_value
      end
    end

    if pdc_field_code.blank?
      errors << "Mapping #{index + 1}: No PDC field found"
      next
    end

    # Get label (instructions field)
    label = if mapping.respond_to?(:pdc_application_field_instructions)
      mapping.pdc_application_field_instructions
    else
      # Fallback: try to get from fluxx field description
      if mapping.respond_to?(:fluxx_field) && mapping.fluxx_field.present?
        fluxx_value = fluxx_field_values[mapping.fluxx_field]
        fluxx_value&.description || "Field #{index + 1}"
      else
        "Field #{index + 1}"
      end
    end

    # Get position
    position = if mapping.respond_to?(:pdc_field_position)
      mapping.pdc_field_position.to_i
    else
      index + 1  # Default to sequential ordering
    end

    # Build field object
    field = {
      baseFieldShortCode: pdc_field_code,
      position: position,
      label: label,
      inputType: nil
    }

    # Add instructions if different from label
    if mapping.respond_to?(:pdc_application_field_instructions) &&
       mapping.pdc_application_field_instructions.present?
      field[:instructions] = mapping.pdc_application_field_instructions
    end

    fields << field

  rescue => e
    errors << "Error processing mapping #{index + 1}: #{e.message}"
  end
end

if fields.empty?
  error_msg = "No valid fields could be prepared for application form"
  error_msg += ". Errors: #{errors.join('; ')}" if errors.any?
  raise error_msg
end

# Sort fields by position
fields.sort_by! { |f| f[:position] }

# Get base URL and auth token
base_url = model.dyn_invoke_for(:"Get PDC Base URL")
auth_token = model.dyn_invoke_for(:"Get Auth Token from PDC")

# Build request body
request_body = {
  opportunityId: opportunity_id.to_i,
  fields: fields,
  name: model.name
}

# Create POST request
endpoint = "#{base_url}/applicationForms"
uri = URI.parse(endpoint)

request = Net::HTTP::Post.new(uri)
request['Authorization'] = "Bearer #{auth_token}"
request['Accept'] = 'application/json'
request['Content-Type'] = 'application/json'
request.body = request_body.to_json

begin
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    http.request(request)
  end

  case response.code
  when "201"
    # Success - parse response
    app_form_data = JSON.parse(response.body)

    # Store PDC application form ID if model supports it
    if model.respond_to?(:pdc_application_form_id=)
      model.update_attribute(:pdc_application_form_id, app_form_data['id'])
    end

    # Return with any mapping errors for visibility
    result = {
      application_form: app_form_data,
      fields_created: fields.length,
      total_mappings: mappings.length
    }
    result[:mapping_errors] = errors if errors.any?

    result

  when "401"
    raise "Unauthorized: Invalid or expired auth token"
  when "404"
    raise "Not found. Verify opportunity ID #{opportunity_id} exists in PDC"
  when "409"
    raise "Conflict: Application form may already exist for this opportunity"
  when "422"
    error_data = JSON.parse(response.body) rescue {}
    error_message = error_data['message'] || response.body
    raise "Invalid data: #{error_message}. Check that all base fields exist in PDC."
  else
    error_data = JSON.parse(response.body) rescue {}
    error_message = error_data['message'] || response.body
    raise "Failed to create application form (#{response.code}): #{error_message}"
  end

rescue Net::OpenTimeout, Net::ReadTimeout
  raise "Timeout connecting to PDC API"
rescue SocketError, Errno::ECONNREFUSED
  raise "Cannot connect to PDC API at #{uri.hostname}"
rescue JSON::ParserError => e
  raise "Invalid JSON response: #{e.message}"
end
