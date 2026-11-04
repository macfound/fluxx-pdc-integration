# Mapped_Field_Warnings
# { mapped field id (string) => warning } for this map's mapped fields that
# have one (see Mapping Warning on PDC Mapped Field). Show Mapped Fields shows
# each under its mapping. Called from Liquid, hence the underscores.

model.reverse_pdc_mapping_field_MacModelTypeDynPdcMappedField1.to_a.each_with_object({}) do |mapping, h|
  warning = (mapping.dyn_invoke_for(:"Mapping Warning") rescue nil)
  h[mapping.id.to_s] = warning.to_s if warning.present?
end
