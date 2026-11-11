# Value For Grant
# What PDC sends for this mapping on one grant: the grant passes itself in as
# @pdc_grant (model.instance_variable_set(:@pdc_grant, grant)) and invokes
# this. Used by PDC Send Proposal to PDC and the consent data preview, so
# both always agree.
#   - Fluxx Field: the field Fluxx Field Source names, on the grant or, for an
#     "Organization (...)" field, on the grant's program organization
#   - Fluxx Related Field - Field Name: when the value is a record (a user,
#     an organization, ...), the named field of that record
#   - a value that is still a record sends its Fluxx id
#   - an empty value sends nil, so the proposal is still created
# Mapping Warning says, from the field definitions alone, when the last two
# will happen.

grant = model.instance_variable_get(:@pdc_grant)
spec = model.dyn_invoke_for(:"Fluxx Field Source")   # which model and field to read
source =
  if grant.nil? || spec.nil? then nil
  elsif spec['model_type'] == 'Organization' then (grant.program_organization if grant.respond_to?(:program_organization))
  else grant
  end
field_name = spec && spec['field']
value = source && source.respond_to?(field_name) ? source.public_send(field_name) : nil

sub = model.respond_to?(:fluxx_related_field_field_name) ? model.fluxx_related_field_field_name.to_s.strip : ''
if !value.nil? && value.respond_to?(:attributes) && !sub.empty? && value.respond_to?(sub)
  value = value.public_send(sub)
end
value = value.id if !value.nil? && value.respond_to?(:attributes) && value.respond_to?(:id)

text = value.to_s.strip
text.empty? ? nil : text
