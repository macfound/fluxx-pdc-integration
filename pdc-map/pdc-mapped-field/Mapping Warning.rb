# Mapping Warning
# A warning for the Integration Map's mapped-field list, worked out from the
# field definitions alone (no grant needed), or nil when the mapping sends
# the field as described. Mirrors Value For Grant:
#   - a Fluxx Field that is a record (a user, an organization, ...) with no
#     Fluxx Related Field - Field Name sends the record's Fluxx id
#   - a related field the record type doesn't have: the same
#   - a Fluxx Field its model doesn't have always sends nothing

spec = model.dyn_invoke_for(:"Fluxx Field Source")   # which model and field it reads
klass = spec && spec['model_type'].safe_constantize
if klass.nil?
  nil
else
  field_name = spec['field']
  label = spec['label']
  # Whether a model type has a field: a method, a column, an association or a
  # dynamic attribute
  has_field = lambda do |k, name|
    k.method_defined?(name) || (k.respond_to?(:column_names) && k.column_names.include?(name)) ||
      (k.respond_to?(:reflect_on_association) && k.reflect_on_association(name.to_sym)) ||
      ModelAttribute.where(model_type: k.name, name: name, deleted_at: nil).exists?
  end
  # The record type a field holds, if it holds one
  assoc = klass.respond_to?(:reflect_on_association) ? klass.reflect_on_association(field_name.to_sym) : nil
  target =
    if assoc && !assoc.polymorphic? then (assoc.klass rescue nil)
    else
      dyn = ModelAttribute.where(model_type: klass.name, name: field_name, attribute_type: 'model', deleted_at: nil).first
      dyn && dyn.value_model_type.to_s.safe_constantize
    end
  sub = model.respond_to?(:fluxx_related_field_field_name) ? model.fluxx_related_field_field_name.to_s.strip : ''
  kind = target ? target.name.demodulize : nil
  if !has_field.call(klass, field_name)
    "#{klass.name} has no field \"#{field_name}\", so this always sends nothing"
  elsif target && sub.empty?
    "#{label} is a #{kind}: this sends its Fluxx ID (nothing when empty). To send something else, set Fluxx Related Field - Field Name (e.g. full_name or name)"
  elsif target && !has_field.call(target, sub)
    "#{kind} has no field \"#{sub}\", so this sends the #{kind}'s Fluxx ID instead. Check Fluxx Related Field - Field Name"
  end
end
