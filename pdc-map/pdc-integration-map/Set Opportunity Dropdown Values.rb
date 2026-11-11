# Set Opportunity Model Attribute Choices
# Fetches all opportunities from PDC and populates model attribute values
# Uses opportunity ID as value and title as description

require 'net/http'
require 'uri'
require 'json'

# Get all opportunities from PDC (handles pagination)
opportunities = model.dyn_invoke_for(:"Get Opportunities from PDC")

# Find the opportunity field attribute
opportunity_attribute = ModelAttribute.find_by(
  model_type: model.class.name,
  name: "opportunity"
)

if opportunity_attribute.nil?
  raise "Opportunity field not found on #{model.class.name}"
end

# Track results
created_count = 0
updated_count = 0
skipped_count = 0
errors = []

# Process each opportunity
opportunities.each do |opp|
  opp_id = opp['id'].to_s
  title = opp['title']

  # Skip if missing required data
  if opp_id.blank? || title.blank?
    errors << "Skipping opportunity with missing ID or title"
    skipped_count += 1
    next
  end

  # Check if value already exists
  existing_value = ModelAttributeValue.find_by(
    model_attribute_id: opportunity_attribute.id,
    value: opp_id,
    deleted_at: nil
  )

  if existing_value
    # Update description if title changed
    if existing_value.description != title
      existing_value.update(description: title)
      updated_count += 1
    else
      skipped_count += 1
    end
  else
    # Create new value
    ModelAttributeValue.create!(
      model_attribute_id: opportunity_attribute.id,
      value: opp_id,
      description: title
    )
    created_count += 1
  end
end

# Return summary
{
  total_opportunities: opportunities.length,
  created: created_count,
  updated: updated_count,
  skipped: skipped_count,
  errors: errors
}
