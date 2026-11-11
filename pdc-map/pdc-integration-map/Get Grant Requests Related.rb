# Method name: PDC_List_Connected_Grants
# Returns serialized data for Liquid consumption

grants = Relationship.where(
  relatable_type: 'GrantRequest',
  related_relatable_type: 'MacModelTypeDynPdcApplicationForm1'
).includes(:relatable, :related_relatable).map do |rel|
  grant = rel.relatable
  form = rel.related_relatable
  
  next if grant.nil? || form.nil?
  
  {
    id: grant.id,
    title: grant.project_title || 'Untitled',
    org: grant.program_organization&.name || 'Unknown',
    form: form.get_dyn_value(:name) || 'Unknown Form',
    pdc_id: grant.pdc_proposal_id || 'Not synced',
    date: rel.created_at.strftime('%Y-%m-%d')
  }
end.compact

Base64.strict_encode64(grants.to_json)