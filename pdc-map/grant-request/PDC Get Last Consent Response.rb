# The latest consent answer on the organization's newest grant that has one, or nil.
# PDC Safe Consent Form Lookup gives each grant's consents with the latest answered last.
grants_on_org = GrantRequest.where(program_organization_id: model.program_organization.id).sort_by { | request | request.created_at }.reverse

latest_consent = nil
grants_on_org.each do | request |
    latest_consent = Array(request.dyn_invoke_for("PDC Safe Consent Form Lookup")).reverse.find { |c| c.consent_type.present? }
    break if latest_consent
end

latest_consent ? latest_consent.consent_type : nil
