opportunity_attribute = ModelAttribute.find_by(
  model_type: model.class.name,
  name: "opportunity"
)

existing_values = ModelAttributeValue.where(
  model_attribute_id: opportunity_attribute.id
).select(:id, :value, :description).to_json

Base64.strict_encode64(existing_values)