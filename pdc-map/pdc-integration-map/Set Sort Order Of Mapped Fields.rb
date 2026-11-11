sorted_mappings = model.dyn_invoke_for(:SortMappedFieldsbyFieldPosition)

ActiveRecord::Base.transaction do
    sorted_mappings.each.with_index do |record, index|
      record.update_attributes(pdc_field_position: index + 1)
    end
  end
