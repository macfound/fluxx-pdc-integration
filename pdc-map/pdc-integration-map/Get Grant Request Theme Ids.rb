# Get Grant Request Theme Ids
# The GrantRequest themes chosen in this map's Grant Request Themes field, as
# theme id strings. Grants of these themes use this map (PDC Get Integration
# Mapping). The field's options are this instance's GrantRequest themes (value =
# theme id), kept current by the PDC deploy record's Refresh Lists and Install.

attr = ModelAttribute.where(model_type: model.class.name, name: 'grant_request_themes', deleted_at: nil).first
options = attr ? ModelAttributeValue.where(model_attribute_id: attr.id).to_a : []
raw = model.respond_to?(:grant_request_themes) ? Array(model.grant_request_themes).flatten.compact : []
raw.map do |v|
  if v.respond_to?(:value) && v.respond_to?(:model_attribute_id)
    v.value.to_s
  else
    s = v.to_s.strip
    hit = options.find { |o| o.id.to_s == s } || options.find { |o| o.value.to_s == s }
    hit ? hit.value.to_s : s
  end
end.reject(&:empty?).uniq
