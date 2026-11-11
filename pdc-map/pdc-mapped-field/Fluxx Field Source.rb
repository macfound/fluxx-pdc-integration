# Fluxx Field Source
# Which model and field this mapping's Fluxx Field reads, as
# { 'model_type' => 'GrantRequest' | 'Organization', 'field' => name, 'label' => shown label },
# or nil. Used by Value For Grant and Mapping Warning.
#
# The field name comes from the Fluxx Field option's value (Set Fluxx Field
# Model Attribute Choices stores "organization.tax_id" for a core field, the
# attribute name for a dynamic one), not from its label: the label is the
# column humanized, which drops "_id" ("tax_id" shows as "Tax"). Only a value
# with no option behind it falls back to the label. A core "x_id" column with
# an x association reads the record (so a Fluxx Related Field can be used); its
# id is what the column holds.

text = model.respond_to?(:fluxx_field) ? model.fluxx_field.to_s.strip : ''
attr = ModelAttribute.where(model_type: model.class.name, name: 'fluxx_field', deleted_at: nil).first
opts = attr && !text.empty? ? ModelAttributeValue.where(model_attribute_id: attr.id, deleted_at: nil) : nil
opt = opts && (opts.where(description: text).first || opts.where(value: text).first)
desc = opt ? opt.description.to_s : text
m = desc.match(/^(\w+)\s*\((core|dynamic)\):\s*(.+?)(?:\s*\[.+?\])?$/)
model_type = m && m[1]
klass = model_type && %w[GrantRequest Organization].include?(model_type) ? model_type.safe_constantize : nil
field =
  if opt && opt.value.to_s.include?('.') then opt.value.to_s.split('.', 2)[1]
  elsif opt then opt.value.to_s
  elsif m then m[3].strip.downcase.gsub(/[\s\-]+/, '_')
  end
if klass && field && field.end_with?('_id') && klass.respond_to?(:reflect_on_association) &&
   klass.reflect_on_association(field.sub(/_id\z/, '').to_sym)
  field = field.sub(/_id\z/, '')
end
klass && field.present? ? { 'model_type' => model_type, 'field' => field, 'label' => m[3].strip } : nil
