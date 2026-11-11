# Update PDC Field Mappings from Application Form
# Creates or updates MacModelTypeDynPdcMappedField1 records
# based on the application form fields from PDC
# Returns summary of actions taken

require 'json'

# Get the application form from PDC
app_form = nil
begin
  app_form = model.dyn_invoke_for(:"Get Application Form by ID from PDC")
rescue => e
  raise "Failed to get application form: #{e.message}"
end

if app_form.nil? || app_form['fields'].nil?
  raise "Application form has no fields to map"
end

# Track results
created_count = 0
updated_count = 0
skipped_count = 0
deleted_count = 0
errors = []

# Pre-load data to avoid N+1 queries
# Get the PDC field attribute
pdc_field_attribute = ModelAttribute.find_by(
  model_type: "MacModelTypeDynPdcMappedField1",
  name: "pdc_field"
)

if pdc_field_attribute.nil?
  raise "PDC field attribute not found on MacModelTypeDynPdcMappedField1"
end

# Load all valid PDC field choices into a Set for fast lookup
valid_pdc_fields = ModelAttributeValue.where(model_attribute_id: pdc_field_attribute.id)
                     .select(:value, :description)
valid_pdc_field_set = Set.new(valid_pdc_fields.map(&:value))

# Load all existing mappings for this application form
# Since pdc_field is dynamic, we need to load the records and access the attribute
existing_mappings = model.reverse_pdc_mapping_field_MacModelTypeDynPdcMappedField1.to_a
existing_pdc_fields = Set.new

# Add valid_pdc_fields where the label matches the to the existing_mappings set so we can use this in a lookup later
existing_mappings.each do |mapping|
  if mapping.respond_to?(:pdc_field) && mapping.pdc_field.present?
    existing_mapping_shortcode = valid_pdc_fields.find_by(description: mapping.pdc_field) # Ensure the field is valid
    existing_pdc_fields.add(existing_mapping_shortcode.value)
  end
end

# Collect mappings to create in batch
mappings_to_create = []

# Process each field in the application form
app_form['fields'].each do |field|
  begin
    # Extract field data
    field_id = field['id']
    pdc_field_code = field['baseFieldShortCode']
    label = field['label']
    position = field['position'] || 0 # Default to 0 if position is not provided
    
    # Skip if missing required data
    if pdc_field_code.blank?
      errors << "Field #{field_id} has no baseFieldShortCode"
      skipped_count += 1
      next
    end
    
    # Check if mapping already exists using pre-loaded data
    if existing_pdc_fields.include?(pdc_field_code)
      skipped_count += 1
    elsif !valid_pdc_field_set.include?(pdc_field_code)
      # PDC field not available as dropdown choice
      errors << "PDC field '#{pdc_field_code}' is not available as a dropdown choice"
      skipped_count += 1
    else
      # Add to batch for creation with pdc_field_code, label and position from the API
      mappings_to_create << { pdc_field: pdc_field_code, label: label, position: position }
    end
    
  rescue => e
    errors << "Error processing field: #{e.message}"
  end
end

# Batch create all mappings
if mappings_to_create.any?
  begin
    # Get the mapping model class
    mapping_class = "MacModelTypeDynPdcMappedField1".constantize
    
    mappings_to_create.each do |mapping_data|
      begin
        # Create the mapping directly on the model
        new_mapping = mapping_class.new
        
        # Set the PDC field
        new_mapping.pdc_field = mapping_data[:pdc_field] if new_mapping.respond_to?(:pdc_field=)
        
        # Set the relationship to the application form using pdc_mapping_field
        if new_mapping.respond_to?(:pdc_mapping_field=)
          new_mapping.pdc_mapping_field = model.id
        else
          raise "pdc_mapping_field field not found on mapping model"
        end

        if new_mapping.respond_to?(:pdc_field_position=)
          # Set the position based on the field's order in the application form
          new_mapping.pdc_field_position = mapping_data[:position]
        end

        if new_mapping.respond_to?(:pdc_application_field_instructions=)
          # Set the label from the application form
          new_mapping.pdc_application_field_instructions = mapping_data[:label]
        end
        
        if new_mapping.save
          created_count += 1
        else
          errors << "Failed to save mapping for #{mapping_data[:pdc_field]}: #{new_mapping.errors.full_messages.join(', ')}"
        end
      rescue => e
        errors << "Error creating mapping for #{mapping_data[:pdc_field]}: #{e.message}"
      end
    end
    # Update the model's last updated timestamp without invoking callbacks
    model.update_attribute(:application_form_last_updated_at, Time.now)
  rescue => e
    errors << "Error during batch creation: #{e.message}"
  end
end

# Remove field mappings that no longer exist in the application form
existing_mappings.each do |mapping|
  begin
    if mapping.respond_to?(:pdc_field) && mapping.pdc_field.present?
      existing_mapping_shortcode = valid_pdc_fields.find_by(description: mapping.pdc_field)
      if existing_mapping_shortcode && !app_form['fields'].any? { |f| f['baseFieldShortCode'] == existing_mapping_shortcode.value }
        # This mapping's PDC field is no longer in the application form, so delete it
        if mapping.destroy
          deleted_count += 1
        else
          errors << "Failed to delete obsolete mapping for #{mapping.pdc_field}: #{mapping.errors.full_messages.join(', ')}"
        end
      end
    end
  rescue => e
    errors << "Error checking/deleting obsolete mapping: #{e.message}"
  end
end

# Return summary
{
  application_form_id: app_form['id'],
  parent_model_id: model.id,
  total_fields: app_form['fields'].length,
  created: created_count,
  updated: updated_count,
  deleted: deleted_count,
  skipped: skipped_count,
  errors: errors
}