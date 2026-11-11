# PDC_Data_Preview
# What will be sent to the PDC for this consent's grant, for the Data Shared
# block on the Consent form: PDC_Get_Data_Preview_For_Proposal on the grant,
# round-tripped through JSON so Liquid only ever gets text, numbers, true/false,
# nil, lists and hashes. Liquid can't render a Fluxx record (it fails with
# "undefined method `to_liquid'"), so the block calls this on the Consent
# instead of reaching through to the grant itself.
# If the preview can't be built (e.g. no active Integration Map has the
# grant's theme), "error" says why and the block shows it.

require 'json'

grant = model.respond_to?(:grant_or_request_id) ? model.grant_or_request_id : nil
if grant.nil?
  { 'display_fields' => [], 'error' => 'This consent has no grant.' }
else
  begin
    JSON.parse(JSON.generate(grant.dyn_invoke_for(:"PDC_Get_Data_Preview_For_Proposal")))
  rescue => e
    { 'display_fields' => [], 'error' => e.message.to_s }
  end
end
