model.retired = false

# Get last funder short code
last_set_funderShortCode = MacModelTypeDynPdcApplicationForm1.where(deleted_at: nil).last&.funder_short_code
if last_set_funderShortCode.present?
  model.funder_short_code = last_set_funderShortCode
end

# Get last opportunity
last_application_form = MacModelTypeDynPdcApplicationForm1.where(deleted_at: nil).last
if last_application_form && last_application_form.respond_to?(:opportunity) && last_application_form.opportunity.present?
  # Get the opportunity attribute
  opportunity_attribute = ModelAttribute.find_by(
    model_type: model.class.name,
    name: "opportunity"
  )
  
  if opportunity_attribute
    # Find the attribute value by description (what's stored in the previous record)
    attr_value = ModelAttributeValue.find_by(
      model_attribute_id: opportunity_attribute.id,
      description: last_application_form.opportunity
    )
    
    # Set using the value (ID), not the description
    if attr_value
      model.opportunity = attr_value.value
    end
  end
end