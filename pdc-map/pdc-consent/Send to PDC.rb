# If someone:
#   changed the dropdown to "Grant Consent"
#   the request record is currently in a granted state
#   and the data has not already been sent before.
if model.consent_type_was != 'Grant consent to share data with the PDC' && model.consent_type == 'Grant consent to share data with the PDC' && model.grant_or_request_id.granted == true && model.grant_data_at_time_of_consent.blank?
    model.grant_or_request_id.dyn_invoke_for(:"PDC Send Proposal to PDC")
end
