# Get All Model Fields for PDC Mapping
# Includes both dynamic attributes and core fields from Grant and Organization models
# Validates duplicates and uses batch operations where possible

require 'set'

arr_models = ["GrantRequest", "Organization"]
fluxx_field = ModelAttribute.where(model_type: "MacModelTypeDynPdcMappedField1", name: "fluxx_field").first

unless fluxx_field
  raise "PDC mapping field configuration not found"
end

# Track existing values to prevent duplicates
existing_values = Set.new(
  ModelAttributeValue.where(model_attribute_id: fluxx_field.id)
                     .pluck(:value)
)

# Track counts for reporting
created_count = 0
skipped_count = 0

arr_models.each do |model_name|
  # Get the actual model class
  model_class = model_name.constantize rescue nil
  next unless model_class

  # 1. Get dynamic attributes
  dynamic_attrs = ModelAttribute.where(
    model_type: model_name,
    multi_allowed: [nil, false],
    include_in_export: true,
    deleted_at: nil
  ).where.not(
    attribute_type: ['model', 'hash']
  ).select(:id, :name, :attribute_type, :description)

  dynamic_attrs.each do |mat|
    if existing_values.include?(mat.name)
      skipped_count += 1
    else
      ModelAttributeValue.create!(
        model_attribute_id: fluxx_field.id,
        description: "#{model_name} (dynamic): #{mat.description}",
        value: mat.name
      )
      existing_values.add(mat.name)
      created_count += 1
    end
  end

  # 2. Get core model fields
  if model_class.respond_to?(:column_names)
    # Filter out system fields and timestamps
    excluded_fields = %w[
      id created_at updated_at deleted_at
      created_by_id updated_by_id delta
      locked_until locked_by_id
    ]

    core_fields = model_class.column_names - excluded_fields

    core_fields.each do |field_name|
      # Create a namespaced value to distinguish core from dynamic
      namespaced_value = "#{model_name.underscore}.#{field_name}"

      if existing_values.include?(namespaced_value)
        skipped_count += 1
      else
        # Get column info for better descriptions
        column = model_class.columns_hash[field_name]
        field_type = column ? column.type.to_s : 'unknown'

        ModelAttributeValue.create!(
          model_attribute_id: fluxx_field.id,
          description: "#{model_name} (core): #{field_name.humanize} [#{field_type}]",
          value: namespaced_value
        )
        existing_values.add(namespaced_value)
        created_count += 1
      end
    end
  end
end

"Created #{created_count} new field mappings, skipped #{skipped_count} existing"
