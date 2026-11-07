# Get Field Mapping JSON for PDC Data Explorer
# Returns Base64-encoded JSON of all field mappings for this application form.
# Intended to be dropped into a data- attribute via Liquid, then decoded by JS.
#
# Output contract (after Base64 decode + JSON.parse):
# {
#   version: 1,
#   application_form_id: Integer,
#   generated_at: ISO8601 string,
#   mappings: [
#     {
#       pdc_field_short_code: String,       # matches PDC API baseFieldShortCode
#       pdc_field_label: String|null,        # human-readable PDC field name
#       fluxx_field_key: String|null,        # e.g. "grant_request[name]" or "program_organization[mission]"
#       fluxx_field_label: String|null,      # original packed description for display
#       position: Integer,                   # display/processing order
#       instructions: String|null            # field-level instructions from the mapping
#     }
#   ]
# }

require 'json'
require 'base64'

# Model name mapping: the packed description uses class names,
# but the front-end needs Fluxx's internal model references.
MODEL_NAME_MAP = {
  "organization"  => "program_organization",
  "grantrequest"  => "grant_request"
}.freeze

# Parse a packed field description like:
#   "Organization (core): Name [string]"
#   "GrantRequest (dynamic): Organization Mission Statement [text]"
# into bracket notation like:
#   "program_organization[name]"
#   "grant_request[organization_mission_statement]"
#
# Returns nil if the string doesn't match the expected pattern.
def parse_fluxx_field_description(description)
  # Pattern: ModelName (type): Field Name [datatype]
  # The data type bracket at the end is optional
  match = description&.match(/\A(\w+)\s*\([^)]+\):\s*(.+?)(?:\s*\[[^\]]+\])?\s*\z/)
  
  if match.nil?
    # Try without parenthetical type: "grant_request.field_name" (core fields
    # stored as namespaced values from Set_Fluxx_Field_Model_Attribute_Choices)
    if description&.include?('.')
      parts = description.split('.', 2)
      model_key = parts[0].downcase.gsub('_', '')
      mapped_model = MODEL_NAME_MAP[model_key] || parts[0]
      return "#{mapped_model}[#{parts[1]}]"
    end
    return nil
  end

  raw_model = match[1]
  raw_field = match[2]

  # Map model name
  model_key = raw_model.downcase.gsub('_', '')
  mapped_model = MODEL_NAME_MAP[model_key] || raw_model.underscore

  # Snake_case the field name
  # "Organization Mission Statement" => "organization_mission_statement"
  snake_field = raw_field
    .strip
    .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')  # handle acronyms
    .gsub(/([a-z\d])([A-Z])/, '\1_\2')        # camelCase boundaries
    .gsub(/\s+/, '_')                          # spaces to underscores
    .downcase

  "#{mapped_model}[#{snake_field}]"
end

# Load mappings from the relationship
mappings = model.reverse_pdc_mapping_field_MacModelTypeDynPdcMappedField1.to_a

# Load ModelAttribute definitions for resolving labels
pdc_field_attribute = ModelAttribute.find_by(
  model_type: "MacModelTypeDynPdcMappedField1",
  name: "pdc_field"
)

fluxx_field_attribute = ModelAttribute.find_by(
  model_type: "MacModelTypeDynPdcMappedField1",
  name: "fluxx_field"
)

# Build lookup hashes
pdc_by_value = {}
pdc_by_description = {}
if pdc_field_attribute
  ModelAttributeValue.where(model_attribute_id: pdc_field_attribute.id).each do |mav|
    pdc_by_value[mav.value] = mav.description
    pdc_by_description[mav.description] = mav.value
  end
end

fluxx_by_value = {}
if fluxx_field_attribute
  ModelAttributeValue.where(model_attribute_id: fluxx_field_attribute.id).each do |mav|
    fluxx_by_value[mav.value] = mav.description
  end
end

# Build the mappings array
resolved_mappings = []

mappings.each_with_index do |mapping, index|
  # Resolve PDC field
  raw_pdc = mapping.respond_to?(:pdc_field) ? mapping.pdc_field : nil
  pdc_short_code = nil
  pdc_label = nil

  if raw_pdc.present?
    if pdc_by_value.key?(raw_pdc)
      pdc_short_code = raw_pdc
      pdc_label = pdc_by_value[raw_pdc]
    elsif pdc_by_description.key?(raw_pdc)
      pdc_short_code = pdc_by_description[raw_pdc]
      pdc_label = raw_pdc
    else
      pdc_short_code = raw_pdc
      pdc_label = nil
    end
  end

  # Resolve Fluxx field
  raw_fluxx = mapping.respond_to?(:fluxx_field) ? mapping.fluxx_field : nil
  fluxx_key = nil
  fluxx_label = nil

  if raw_fluxx.present?
    fluxx_label = fluxx_by_value[raw_fluxx] || raw_fluxx

    # Parse the packed description into bracket notation.
    # Try the description first (human-readable), fall back to the raw value
    # which may already be in "model.field" notation for core fields.
    fluxx_key = parse_fluxx_field_description(fluxx_label)
    fluxx_key ||= parse_fluxx_field_description(raw_fluxx)
  end

  # Position
  position = if mapping.respond_to?(:pdc_field_position) && mapping.pdc_field_position.present?
    mapping.pdc_field_position.to_i
  else
    index + 1
  end

  # Instructions
  instructions = if mapping.respond_to?(:pdc_application_field_instructions)
    mapping.pdc_application_field_instructions.presence
  else
    nil
  end

  resolved_mappings << {
    pdc_field_short_code: pdc_short_code,
    pdc_field_label: pdc_label,
    fluxx_field_key: fluxx_key,
    fluxx_field_label: fluxx_label,
    position: position,
    instructions: instructions
  }
end

# Sort by position
resolved_mappings.sort_by! { |m| m[:position] }

# Build envelope
payload = {
  version: 1,
  application_form_id: model.id,
  generated_at: Time.current.iso8601,
  mappings: resolved_mappings
}