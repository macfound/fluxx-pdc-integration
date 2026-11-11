# Set Application Dropdown Values
# Fetches all application forms from PDC and populates model attribute values
# Uses application form ID for value and includes opportunity ID in description for filtering
# Only live values are matched; a deleted value is never reused

require 'net/http'
require 'uri'
require 'json'

# Get all application forms from PDC
applications = model.dyn_invoke_for(:"Get Applications from PDC")

# Find the application field attribute
application_attribute = ModelAttribute.find_by(
  model_type: model.class.name,
  name: "application"
)

if application_attribute.nil?
  raise "Application field not found on #{model.class.name}"
end

# Track results
created_count = 0
updated_count = 0
skipped_count = 0
errors = []

# Process each application form
applications.each do |app|
  app_id = app['id'].to_s
  opportunity_id = app['opportunityId'].to_s

  # Skip if missing required data
  if app_id.blank?
    errors << "Skipping application with missing ID"
    skipped_count += 1
    next
  end

  # Create display text with parseable opportunity ID
  # Format: "Application #ID (Opp: OPPORTUNITY_ID, v.VERSION)"
  version = app['version'] || 'unknown'
  display_text = "Application ##{app_id} (Opp: #{opportunity_id}, v.#{version})"

  # Check if a live value exists
  existing_value = ModelAttributeValue.unscoped.find_by(
    model_attribute_id: application_attribute.id,
    value: app_id,
    deleted_at: nil
  )

  if existing_value
    if existing_value.description != display_text
      # Update description if changed
      existing_value.update(description: display_text)
      updated_count += 1
    else
      skipped_count += 1
    end
  else
    # Create new value
    ModelAttributeValue.create!(
      model_attribute_id: application_attribute.id,
      value: app_id,
      description: display_text
    )
    created_count += 1
  end
end

# Return summary
{
  total_applications: applications.length,
  created: created_count,
  updated: updated_count,
  skipped: skipped_count,
  errors: errors
}
