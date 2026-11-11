# If has not been granted before, stamp the consent info, including the relationship and the data at time of consent.
if model.granted_at.blank? && model.consent_type == 'Grant consent to share data with the PDC'
    current_user = User.find_current_user
    model.update_attributes( 
           granted_by_first_name: current_user.first_name,
           granted_by_last_name: current_user.last_name,
           grant_data_at_time_of_consent: model.grant_or_request_id.dyn_invoke_for(:"PDC_Get_Data_Preview_For_Proposal"),
           granted_at: Time.now,
           granted_by: current_user
       )
end