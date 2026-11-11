mappings = model.reverse_pdc_mapping_field_MacModelTypeDynPdcMappedField1.to_a
  
# Sort with nil handling - nils go to end
sorted_mappings = mappings.sort_by do |mapping|
  position = mapping.respond_to?(:pdc_field_position) ? mapping.pdc_field_position : nil
  [position.nil? ? 1 : 0, position.to_i]
end

sorted_mappings