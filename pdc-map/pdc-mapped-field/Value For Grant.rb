# Value For Grant
# What PDC sends for this mapping on one grant: the grant passes itself in as
# @pdc_grant (model.instance_variable_set(:@pdc_grant, grant)) and invokes
# this. Used by PDC Send Proposal to PDC and the consent data preview, so
# both always agree.
#   - Fluxx Field: "GrantRequest (core): Project Title [string]" reads
#     project_title from the grant; "Organization (...)" reads it from the
#     grant's program organization
#   - Fluxx Related Field - Field Name: when the value is a record (a user,
#     an organization, ...), the named field of that record
#   - a value that is still a record sends its Fluxx id
#   - an empty value sends nil, so the proposal is still created
# Mapping Warning says, from the field definitions alone, when the last two
# will happen.

grant = model.instance_variable_get(:@pdc_grant)
desc = model.respond_to?(:fluxx_field) ? model.fluxx_field.to_s : ''
m = desc.match(/^(\w+)\s*\((core|dynamic)\):\s*(.+?)(?:\s*\[.+?\])?$/)
source =
  if grant.nil? || m.nil? then nil
  elsif m[1] == 'Organization' then (grant.program_organization if grant.respond_to?(:program_organization))
  elsif m[1] == 'GrantRequest' then grant
  end
field_name = m && m[3].strip.downcase.gsub(/[\s\-]+/, '_')
value = source && source.respond_to?(field_name) ? source.public_send(field_name) : nil

sub = model.respond_to?(:fluxx_related_field_field_name) ? model.fluxx_related_field_field_name.to_s.strip : ''
if !value.nil? && value.respond_to?(:attributes) && !sub.empty? && value.respond_to?(sub)
  value = value.public_send(sub)
end
value = value.id if !value.nil? && value.respond_to?(:attributes) && value.respond_to?(:id)

text = value.to_s.strip
text.empty? ? nil : text
