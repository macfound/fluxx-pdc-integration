# Set PDC Field Model Attribute Choices
# Populates the pdc_field dropdown from the PDC base field list.
# Fetch and pagination live in Get Base Fields from PDC.

pdc_base_fields = model.dyn_invoke_for(:"Get Base Fields from PDC")

if pdc_base_fields.nil? || pdc_base_fields.empty?
  raise "No base fields returned from PDC. Refusing to run against an empty list."
end

# Note the casing: the attribute in the database is MacModelTypeDynPdcMappedField1.
pdc_field_attribute = ModelAttribute.find_by(
  model_type: "MacModelTypeDynPdcMappedField1",
  name:       "pdc_field"
)

if pdc_field_attribute.nil?
  raise "pdc_field attribute not found on MacModelTypeDynPdcMappedField1"
end

created_count = 0
updated_count = 0
skipped_count = 0
errors        = []

# One query instead of one per field
existing = {}
ModelAttributeValue.where(model_attribute_id: pdc_field_attribute.id).each do |mav|
  existing[mav.value] = mav
end

pdc_base_fields.each do |field|
  short_code = field['shortCode']
  label      = field['label']

  if short_code.blank?
    errors << "Skipping field with no shortCode: #{field.inspect[0, 120]}"
    skipped_count += 1
    next
  end

  # Fall back to the short code so a missing label does not drop the field
  description = label.presence || short_code

  current = existing[short_code]

  if current
    if current.description != description
      current.update(description: description)
      updated_count += 1
    else
      skipped_count += 1
    end
  else
    begin
      ModelAttributeValue.create!(
        model_attribute_id: pdc_field_attribute.id,
        value:              short_code,
        description:        description
      )
      created_count += 1
    rescue => e
      errors << "Failed to create #{short_code}: #{e.message}"
    end
  end
end

{
  total_fields:  pdc_base_fields.length,
  created:       created_count,
  updated:       updated_count,
  skipped:       skipped_count,
  final_count:   ModelAttributeValue.where(model_attribute_id: pdc_field_attribute.id).count,
  errors:        errors
}
