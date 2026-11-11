# PDC Save Credentials (before_save on the deploy model)
#
# The PDC Client ID / PDC Client Secret fields on the deploy record's form are
# only a way to enter the values. On every save:
#   - a field that holds a value is written into the Get PDC Client ID /
#     Get PDC Client Secret method on the PDC Integration Map (created if
#     missing; the value is quoted so it's always valid Ruby)
#   - both fields are cleared before the record is stored, so the values never
#     stay on this record, in its results or in snapshots
# What happened (never the values) is shown on the form as "Credentials".

require 'json'

credential_fields = { 'pdc_client_id_input' => 'Get PDC Client ID', 'pdc_client_secret_input' => 'Get PDC Client Secret' }
target_model = 'MacModelTypeDynPdcApplicationForm1'
entries = []

credential_fields.each do |field, method_name|
  next unless model.respond_to?(field) && model.respond_to?("#{field}=")
  value = model.public_send(field).to_s.strip
  model.public_send("#{field}=", nil)   # never kept on the record
  next if value.empty?
  if value =~ /[\r\n]/
    entries << { 'status' => 'not saved', 'key' => method_name, 'detail' => 'the value contained a line break' }
    next
  end
  unless MachineModelType.where(model_type: target_model, deleted_at: nil).exists?
    entries << { 'status' => 'not saved', 'key' => method_name, 'detail' => 'the PDC Integration Map does not exist yet: click Install first, then enter it again' }
    next
  end
  body = "# #{method_name}: set from the PDC deploy record on #{Time.now.utc.strftime('%Y-%m-%d')}. To change it,\n" \
         "# enter the new value there, or replace the quoted value here (keeping the quotes).\n" \
         "#{value.inspect}"
  rel = ModelMethod.where(model_type: target_model, name: method_name)
  rec = rel.where(deleted_at: nil).first || rel.where.not(deleted_at: nil).order(deleted_at: :desc).first ||
        ModelMethod.new(model_type: target_model, name: method_name, method_type: 'method')
  rec.deleted_at = nil if rec.respond_to?(:deleted_at=)
  rec.unsafe_dyn_method = body
  rec.save!
  entries << { 'status' => 'saved', 'key' => method_name }
end

unless entries.empty?
  record = begin
    model.dyn_invoke_for(:"PDC Installer Lib")[:results_record].call('Credentials', 'entered on this form', entries)
  rescue => e
    { 'title' => 'Credentials', 'mode' => 'entered on this form', 'ran_at' => Time.now.utc.to_s,
      'groups' => entries.group_by { |x| x['status'] }.map { |st, xs| { 'label' => st, 'tone' => st == 'saved' ? 'done' : 'bad', 'items' => xs } } }
  end
  model.credentials_results = JSON.generate(record) if model.respond_to?(:credentials_results=)
end
nil
