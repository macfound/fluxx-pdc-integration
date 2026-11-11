# Ruby Method: "Get PDC Field Mapping"
# Model: GrantRequest
#
# Purpose:
#   Finds this grant's PDC Integration Map (PDC Get Integration Mapping: the
#   active map whose Grant Request Themes include the grant's theme), invokes
#   "Get Field Mapping JSON for PDC Data Explorer" on it, and returns the
#   Base64-encoded JSON result.
#
#   This indirection exists because there is no direct relationship
#   between a grant and the PDC integration map. The grant's method
#   resolves the map at render time (when the stencil loads), not
#   at save time.
#
# Output:
#   Base64-encoded JSON string (same contract as the underlying method).
#   Returns empty string if no map has this grant's theme, or more than one does.
#
# Invoked from Liquid as:
#   {% assign mapping_data = model."Get PDC Field Mapping" %}

# ---- Method body ----

# An error here would be rendered into the stencil, so a theme on two active
# maps shows no mapping rather than the error.
map_record = begin
  model.dyn_invoke_for(:"PDC Get Integration Mapping")
rescue
  nil
end

# NOTE: this body is a Fluxx dynamic model method, not a real Ruby method, so a
# top-level `return` raises LocalJumpError ("unexpected return") and corrupts the
# rendered stencil (the error string is injected as HTML). Use a conditional
# expression as the method's return value instead of an early `return`.
if map_record.nil?
  ""
else
  Base64.strict_encode64(map_record.dyn_invoke_for(:"Get Field Mapping JSON for PDC Data Explorer").to_json)
end
