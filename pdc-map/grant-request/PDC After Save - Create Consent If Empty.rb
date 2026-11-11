# If program_organzation is set and the consent form has not been created, create it.
# This can't be on "before_new" or "after_create" because we couldn't default consent from previous forms.
# Only allows creation of consent forms on models created on or after 07/01/2026. (Date.parse reads "dd/MM/yyyy")

if model.created_at >= Date.parse("01/07/2026") && !model.program_organization.blank? && model.dyn_invoke_for(:"PDC Safe Consent Form Lookup").blank?
  model.dyn_invoke_for(:"PDC Create Consent Form")
end
