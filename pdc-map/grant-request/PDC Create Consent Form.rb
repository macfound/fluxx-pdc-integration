# If this is the very first consent form, we need to create a blank one so we can invoke methods on it.
# If this has been initialized, we will just use that and not delete it in the end.
firstConsentForm = MacModelTypeDynPdcConsent.first
deleteInitialForm = false
if firstConsentForm == nil
  firstConsentForm = MacModelTypeDynPdcConsent.create!(
    created_at: Time.now,
    created_by: current_user,
    updated_at: Time.now,
    updated_by: current_user
  )
  deleteInitialForm = true
end

MacModelTypeDynPdcConsent.create(
  grant_or_request_id: model.id,
  consent_language: firstConsentForm.dyn_invoke_for(:CurrentConsentLanguage),
  consent_language_version: firstConsentForm.dyn_invoke_for(:CurrentConsentVersion),
  consent_type: model.dyn_invoke_for(:"PDC Get Last Consent Response"),
  created_at: Time.now,
  created_by: current_user,
  updated_at: Time.now,
  updated_by: current_user
).save

if deleteInitialForm == true
  firstConsentForm.delete()
end
