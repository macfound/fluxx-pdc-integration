# PDC Safe Consent Form Lookup
# This grant's PDC Consent records, deleted ones left out, ordered by last update so .last is the
# one most recently answered. Read from the database: the related-data tab (rd_tab_dyn_models)
# can include deleted records and misses a consent made earlier in the same request, which let
# the After Save hook make one consent per save of a new grant. Its records are still merged in,
# in case a link is stored somewhere the query below doesn't look.
link = ModelAttribute.where(model_type: 'MacModelTypeDynPdcConsent', name: 'grant_or_request_id', deleted_at: nil).first
ids = link ? ModelAttributeChoice.where(model_attribute_id: link.id).where('model_value_id = :id OR integer_value = :id', id: model.id).pluck(:model_id) : []
consents = MacModelTypeDynPdcConsent.where(id: ids, deleted_at: nil).to_a

tab = begin
    model.rd_tab_dyn_models("MacModelTypeDynPdcConsent")
rescue NoMethodError => e
    raise unless e.message.include?("collect") && e.message.include?("nil:NilClass")
    []
end
Array(tab).each do |c|
    consents << c if c && (!c.respond_to?(:deleted_at) || c.deleted_at.nil?) && consents.none? { |k| k.id == c.id }
end

consents.sort_by { |c| [c.updated_at || c.created_at || Time.at(0), c.id] }
